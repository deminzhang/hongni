package blob

import (
	"bufio"
	"bytes"
	"image"
	"image/jpeg"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/image/draw"
	_ "golang.org/x/image/webp" // register WebP decoder
	_ "image/gif"               // register GIF decoder
	_ "image/png"               // register PNG decoder
)

// Store manages content-addressed blob and thumbnail files on disk.
type Store struct {
	dataDir   string
	blobsDir  string
	thumbsDir string
}

// New returns a Store rooted at dataDir (which contains blobs/ and thumbs/).
func New(dataDir string) *Store {
	return &Store{
		dataDir:   dataDir,
		blobsDir:  filepath.Join(dataDir, "blobs"),
		thumbsDir: filepath.Join(dataDir, "thumbs"),
	}
}

func (s *Store) blobDir(hash string) string {
	return filepath.Join(s.blobsDir, hash[0:2], hash[2:4])
}

// blobPath returns the on-disk path for a blob with the given extension. The
// extension is a pure function of the content (see extensionOfContent), so a
// hash always maps to exactly one path even though it may be shared by many
// assets — content addressing is preserved and deduplication stays intact.
func (s *Store) blobPath(hash, ext string) string {
	return filepath.Join(s.blobDir(hash), hash+"."+ext)
}

// resolveBlobPath locates the physical blob file for a hash. Blobs are
// content-addressed and the extension is derived from content, so at most one
// "<hash>.<ext>" file exists for a given hash. It also tolerates the legacy
// bare "<hash>" layout so any un-migrated blob remains readable.
func (s *Store) resolveBlobPath(hash string) (string, error) {
	matches, err := filepath.Glob(filepath.Join(s.blobDir(hash), hash+".*"))
	if err != nil {
		return "", err
	}
	if len(matches) > 0 {
		return matches[0], nil
	}
	return filepath.Join(s.blobDir(hash), hash), nil
}

// Put writes the blob content addressed by hash, atomically, skipping the
// write if the file already exists (deduplication). The stored file is named
// "<hash>.<ext>" where ext is derived from the content itself, so the hash
// stays a stable, unique content address regardless of the visible extension.
func (s *Store) Put(hash string, r io.Reader) error {
	br := bufio.NewReader(r)
	head, _ := br.Peek(512)
	p := s.blobPath(hash, extensionOfContent(head))

	if _, err := os.Stat(p); err == nil {
		return nil
	}
	return writeFileAtomic(p, func(w io.Writer) error {
		_, err := io.Copy(w, br)
		return err
	})
}

// writeFileAtomic writes a file through a uniquely named temp file next to it
// and renames it over the destination. The unique name is not cosmetic: two
// uploads of the same content can race to the same destination (the dedup check
// is a lookup, not a lock), and a shared "<path>.tmp" would let their writes
// interleave into one file. Renaming inside a directory is atomic, so a reader
// — or a client that crashed mid-transfer — sees either nothing or the whole
// file, never a truncated one. This matters most where writes are slow and
// interrupted often: a network share (SMB/NAS).
func writeFileAtomic(path string, write func(io.Writer) error) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, filepath.Base(path)+".*.tmp")
	if err != nil {
		return err
	}
	tmp := f.Name()
	if err := write(f); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		// A lost race is not a failure: the destination is derived from the
		// content, so whoever got there first wrote these same bytes. Windows
		// reports the collision as "Access is denied" (it will not replace a
		// destination someone else has open), and rename is atomic, so anything
		// sitting at the destination is a whole file — not a truncated one. Only
		// a destination that is genuinely absent makes this a real error.
		if _, statErr := os.Stat(path); statErr == nil {
			return nil
		}
		return err
	}
	return nil
}

// Open returns a reader over the stored blob.
func (s *Store) Open(hash string) (io.ReadCloser, error) {
	p, err := s.resolveBlobPath(hash)
	if err != nil {
		return nil, err
	}
	return os.Open(p)
}

// OpenThumb returns a reader over the stored thumbnail, if present.
func (s *Store) OpenThumb(hash string) (io.ReadCloser, error) {
	return os.Open(s.thumbPath(hash))
}

// Delete removes both the blob and its thumbnail, ignoring missing files.
func (s *Store) Delete(hash string) error {
	bp, err := s.resolveBlobPath(hash)
	if err != nil {
		return err
	}
	for _, p := range []string{bp, s.thumbPath(hash)} {
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	return nil
}

func (s *Store) thumbPath(hash string) string {
	return filepath.Join(s.thumbsDir, hash[0:2], hash[2:4], hash+".jpg")
}

// MigrateLegacyBlobs renames legacy blob files stored as bare "<hash>" (no
// extension) to "<hash>.<ext>" using the content-derived extension. It is
// idempotent: files already named "<hash>.<ext>" are skipped. Only blobs/
// (sharded two levels deep) is examined; thumbnails are untouched.
func (s *Store) MigrateLegacyBlobs() error {
	return filepath.WalkDir(s.blobsDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		base := filepath.Base(path)
		// Legacy blobs are 64-hex-char names with no dot.
		if len(base) != 64 || strings.ContainsAny(base, ".") {
			return nil
		}
		f, err := os.Open(path)
		if err != nil {
			return err
		}
		head := make([]byte, 512)
		n, _ := io.ReadFull(f, head)
		f.Close()
		ext := extensionOfContent(head[:n])
		return os.Rename(path, filepath.Join(filepath.Dir(path), base+"."+ext))
	})
}

// maxImagePixels bounds what one image may decode to (≈200 MP, far past any
// phone camera). The thumbnail pass decodes at full size to scale from, so an
// image whose header claims absurd dimensions would otherwise be an allocation
// the process cannot survive. Oversized images are still stored and served
// byte-for-byte — they just do not get a thumbnail.
const maxImagePixels = 200_000_000

// EnsureThumb decodes r once and, when decodable, writes a max-512px JPEG
// thumbnail. It returns ok=false for undecodable content (HEIC, video) and for
// images past maxImagePixels, with no error, and true when a thumbnail exists or
// was just created. r must be seekable: the header is read first and the stream
// rewound for the decode.
func (s *Store) EnsureThumb(hash string, r io.ReadSeeker) (bool, error) {
	tp := s.thumbPath(hash)
	if _, err := os.Stat(tp); err == nil {
		return true, nil
	}

	cfg, _, err := image.DecodeConfig(r)
	if err != nil {
		return false, nil
	}
	if cfg.Width <= 0 || cfg.Height <= 0 || int64(cfg.Width)*int64(cfg.Height) > maxImagePixels {
		return false, nil
	}
	if _, err := r.Seek(0, io.SeekStart); err != nil {
		return false, err
	}

	img, _, err := image.Decode(r)
	if err != nil {
		return false, nil
	}

	if err := writeFileAtomic(tp, func(w io.Writer) error {
		return jpeg.Encode(w, scaleDown(img, 512), &jpeg.Options{Quality: 82})
	}); err != nil {
		return false, err
	}
	return true, nil
}

// Dimensions reports the decoded image width/height without materializing the
// full image. Used to populate asset metadata for images.
func Dimensions(r io.Reader) (int, int, bool) {
	cfg, _, err := image.DecodeConfig(r)
	if err != nil {
		return 0, 0, false
	}
	return cfg.Width, cfg.Height, true
}

// extensionOfContent derives a file extension from the leading bytes of the
// content. It is a pure function of the bytes, so identical content always
// yields the same extension and deduplication by hash stays intact. Unknown
// formats fall back to "bin" so every blob still carries a visible extension
// and remains identifiable on disk without relying on the database or tools.
func extensionOfContent(b []byte) string {
	switch {
	case len(b) >= 8 && bytes.Equal(b[:8], pngSig):
		return "png"
	case len(b) >= 3 && b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff:
		return "jpg"
	case len(b) >= 4 && bytes.Equal(b[:4], []byte("GIF8")):
		return "gif"
	case len(b) >= 12 && bytes.Equal(b[:4], []byte("RIFF")) && bytes.Equal(b[8:12], []byte("WEBP")):
		return "webp"
	case len(b) >= 2 && b[0] == 'B' && b[1] == 'M':
		return "bmp"
	case len(b) >= 12 && bytes.Equal(b[4:8], bmffSig):
		switch brand := b[8:12]; {
		case bytes.Equal(brand, []byte("heic")),
			bytes.Equal(brand, []byte("heix")),
			bytes.Equal(brand, []byte("hevc")),
			bytes.Equal(brand, []byte("hevx")),
			bytes.Equal(brand, []byte("mif1")),
			bytes.Equal(brand, []byte("msf1")):
			return "heic"
		case bytes.Equal(brand, []byte("qt  ")):
			return "mov"
		default:
			return "mp4"
		}
	case len(b) >= 4 && bytes.Equal(b[:4], ebmlSig):
		return "mkv"
	case len(b) >= 12 && bytes.Equal(b[:4], []byte("RIFF")) && bytes.Equal(b[8:12], []byte("AVI ")):
		return "avi"
	default:
		return "bin"
	}
}

var (
	pngSig  = []byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a}
	bmffSig = []byte("ftyp")
	ebmlSig = []byte{0x1a, 0x45, 0xdf, 0xa3}
)

func scaleDown(src image.Image, max int) image.Image {
	b := src.Bounds()
	w, h := b.Dx(), b.Dy()
	if w <= max && h <= max {
		return src
	}
	var nw, nh int
	if w >= h {
		nw = max
		nh = h * max / w
	} else {
		nh = max
		nw = w * max / h
	}
	if nw < 1 {
		nw = 1
	}
	if nh < 1 {
		nh = 1
	}
	dst := image.NewRGBA(image.Rect(0, 0, nw, nh))
	draw.CatmullRom.Scale(dst, dst.Bounds(), src, b, draw.Over, nil)
	return dst
}
