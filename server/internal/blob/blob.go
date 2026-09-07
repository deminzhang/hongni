package blob

import (
	"image"
	"image/jpeg"
	"io"
	"os"
	"path/filepath"

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

func (s *Store) blobPath(hash string) string {
	return filepath.Join(s.blobsDir, hash[0:2], hash[2:4], hash)
}

func (s *Store) thumbPath(hash string) string {
	return filepath.Join(s.thumbsDir, hash[0:2], hash[2:4], hash+".jpg")
}

// Put writes the blob content addressed by hash, atomically, skipping the
// write if the file already exists (deduplication).
func (s *Store) Put(hash string, r io.Reader) error {
	p := s.blobPath(hash)
	if _, err := os.Stat(p); err == nil {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	tmp := p + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, r); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, p)
}

// Open returns a reader over the stored blob.
func (s *Store) Open(hash string) (io.ReadCloser, error) {
	return os.Open(s.blobPath(hash))
}

// OpenThumb returns a reader over the stored thumbnail, if present.
func (s *Store) OpenThumb(hash string) (io.ReadCloser, error) {
	return os.Open(s.thumbPath(hash))
}

// Delete removes both the blob and its thumbnail, ignoring missing files.
func (s *Store) Delete(hash string) error {
	for _, p := range []string{s.blobPath(hash), s.thumbPath(hash)} {
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	return nil
}

// EnsureThumb decodes r once and, when decodable, writes a max-512px JPEG
// thumbnail. It returns ok=false for undecodable content (HEIC, video) with no
// error, and true when a thumbnail exists or was just created.
func (s *Store) EnsureThumb(hash string, r io.Reader) (bool, error) {
	tp := s.thumbPath(hash)
	if _, err := os.Stat(tp); err == nil {
		return true, nil
	}

	img, _, err := image.Decode(r)
	if err != nil {
		return false, nil
	}

	if err := os.MkdirAll(filepath.Dir(tp), 0o755); err != nil {
		return false, err
	}
	f, err := os.Create(tp)
	if err != nil {
		return false, err
	}
	defer f.Close()

	thumb := scaleDown(img, 512)
	if err := jpeg.Encode(f, thumb, &jpeg.Options{Quality: 82}); err != nil {
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
