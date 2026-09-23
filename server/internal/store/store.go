package store

import (
	"context"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

// Asset mirrors a row in the assets table.
type Asset struct {
	ID           int64  `json:"id"`
	Hash         string `json:"hash"`
	OriginalName string `json:"original_name"`
	Ext          string `json:"ext"`
	MediaType    string `json:"media_type"`
	MimeType     string `json:"mime_type"`
	Size         int64  `json:"size"`
	Width        *int64 `json:"width"`
	Height       *int64 `json:"height"`
	TakenAt      *int64 `json:"taken_at"`
	CreatedAt    int64  `json:"created_at"`

	// Trash/最近删除 state. DeletedAt is NULL for active assets; non-NULL marks
	// the asset soft-deleted into the per-trunk recycle bin. DeletedTrunkID and
	// DeletedAlbumID capture where it was deleted from so Restore can return it
	// to its original album (or the trunk's 散照 bucket if that album is gone).
	DeletedAt      *int64 `json:"deleted_at"`
	DeletedTrunkID *int64 `json:"deleted_trunk_id"`
	DeletedAlbumID *int64 `json:"deleted_album_id"`
}

// Album mirrors a row in the albums table. OwnerID is NULL for a shared album
// (every identity sees it) and the owning identity for a 隐私 sub-tree.
type Album struct {
	ID        int64  `json:"id"`
	Name      string `json:"name"`
	ParentID  *int64 `json:"parent_id"`
	IsHidden  int64  `json:"is_hidden"`
	SyncMode  string `json:"sync_mode"`
	SortOrder int64  `json:"sort_order"`
	CreatedAt int64  `json:"created_at"`
	OwnerID   *int64 `json:"owner_id"`
}

// Change mirrors a sync_log row, returned by the /sync/changes endpoint.
type Change struct {
	Seq      int64  `json:"seq"`
	Entity   string `json:"entity"`
	EntityID int64  `json:"entity_id"`
	Op       string `json:"op"`
	At       int64  `json:"at"`
}

// Store wraps the SQLite database handle.
type Store struct {
	db *sql.DB
}

const schema = `
CREATE TABLE IF NOT EXISTS blobs (
  hash      TEXT PRIMARY KEY,
  size      INTEGER NOT NULL,
  ref_count INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS assets (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  hash          TEXT NOT NULL REFERENCES blobs(hash),
  original_name TEXT NOT NULL,
  ext           TEXT,
  media_type    TEXT NOT NULL CHECK (media_type IN ('image','video')),
  mime_type     TEXT NOT NULL,
  size          INTEGER NOT NULL,
  width         INTEGER,
  height        INTEGER,
  taken_at      INTEGER,
  created_at    INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_assets_hash ON assets(hash);

CREATE TABLE IF NOT EXISTS albums (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  name       TEXT NOT NULL,
  parent_id  INTEGER REFERENCES albums(id) ON DELETE CASCADE,
  is_hidden  INTEGER NOT NULL DEFAULT 0,
  sync_mode  TEXT NOT NULL DEFAULT 'backup'
             CHECK (sync_mode IN ('backup','local_only','two_way','mirror')),
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS album_assets (
  album_id INTEGER NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
  asset_id INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
  added_at INTEGER NOT NULL,
  PRIMARY KEY (album_id, asset_id)
);

CREATE TABLE IF NOT EXISTS sync_log (
  seq       INTEGER PRIMARY KEY AUTOINCREMENT,
  entity    TEXT NOT NULL CHECK (entity IN ('asset','album','album_asset')),
  entity_id INTEGER NOT NULL,
  op        TEXT NOT NULL CHECK (op IN ('create','update','delete')),
  at        INTEGER NOT NULL
);

-- A family member. The PIN is never stored: only its PBKDF2 hash, with the
-- iteration count kept per row so raising the cost later leaves old rows valid.
CREATE TABLE IF NOT EXISTS identities (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  name       TEXT NOT NULL UNIQUE,
  pin_salt   TEXT NOT NULL,
  pin_hash   TEXT NOT NULL,
  iterations INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
`

// Open opens (creating if necessary) the SQLite database at path with the
// given journal mode, enables foreign keys, and applies the schema migration.
// The mode is a parameter because WAL — the default and the fastest — is only
// sound on a local disk: it keeps its index in a memory-mapped "-shm" file that
// network filesystems do not arbitrate between hosts, so a data directory on
// SMB/NAS has to run a rollback journal (DELETE/TRUNCATE) instead.
func Open(path, journal string) (*Store, error) {
	dsn := path + "?_pragma=journal_mode(" + journal + ")&_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// Single connection avoids SQLITE_BUSY contention and keeps the
	// per-connection PRAGMAs effective for the lifetime of the store.
	db.SetMaxOpenConns(1)

	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}
	st := &Store{db: db}
	if err := st.migrate(); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}
	if err := st.seedTrunks(); err != nil {
		db.Close()
		return nil, fmt.Errorf("seed trunks: %w", err)
	}
	return st, nil
}

// migrate applies backward-compatible column additions. SQLite errors on a
// duplicate ALTER TABLE ADD COLUMN, so each column is added only when missing.
func (s *Store) migrate() error {
	cols := []struct{ table, name, ddl string }{
		{"assets", "deleted_at", "ALTER TABLE assets ADD COLUMN deleted_at INTEGER"},
		{"assets", "deleted_trunk_id", "ALTER TABLE assets ADD COLUMN deleted_trunk_id INTEGER"},
		{"assets", "deleted_album_id", "ALTER TABLE assets ADD COLUMN deleted_album_id INTEGER"},
		{"assets", "deleted_album_name", "ALTER TABLE assets ADD COLUMN deleted_album_name TEXT"},
		{"assets", "deleted_name", "ALTER TABLE assets ADD COLUMN deleted_name TEXT"},
		{"album_assets", "name", "ALTER TABLE album_assets ADD COLUMN name TEXT"},
		{"assets", "ext", "ALTER TABLE assets ADD COLUMN ext TEXT"},
		{"albums", "owner_id", "ALTER TABLE albums ADD COLUMN owner_id INTEGER"},
	}
	extAdded := false
	for _, c := range cols {
		exists, err := s.columnExists(c.table, c.name)
		if err != nil {
			return err
		}
		if exists {
			continue
		}
		if _, err := s.db.Exec(c.ddl); err != nil {
			return fmt.Errorf("migrate %s.%s: %w", c.table, c.name, err)
		}
		if c.name == "ext" {
			extAdded = true
		}
	}
	// Backfill ext for rows created before the dedicated column existed, so the
	// original extension survives even after original_name is later renamed.
	if extAdded {
		return s.backfillExt()
	}
	return nil
}

// backfillExt derives ext from original_name for assets that predate the ext
// column. It is only called right after the column is added, so it is a one-off
// cost on upgrade rather than a scan on every startup.
func (s *Store) backfillExt() error {
	rows, err := s.db.Query(`SELECT id, original_name FROM assets`)
	if err != nil {
		return err
	}
	defer rows.Close()
	type row struct {
		id   int64
		name string
	}
	var items []row
	for rows.Next() {
		var r row
		if err := rows.Scan(&r.id, &r.name); err != nil {
			return err
		}
		items = append(items, r)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	for _, r := range items {
		if _, err := s.db.Exec(`UPDATE assets SET ext = ? WHERE id = ?`, ExtensionOf(r.name), r.id); err != nil {
			return err
		}
	}
	return nil
}

// ExtensionOf returns the lowercase file extension without the leading dot for
// a filename, e.g. "jpg". It uses the last dot, so multi-dot names like
// "photo.2024.jpg" yield "jpg"; empty when the name has no extension.
func ExtensionOf(name string) string {
	if i := strings.LastIndexByte(name, '.'); i >= 0 && i+1 < len(name) {
		return strings.ToLower(name[i+1:])
	}
	return ""
}

func (s *Store) columnExists(table, column string) (bool, error) {
	var n int
	// Table is a fixed identifier; only the column is bound.
	err := s.db.QueryRow("SELECT COUNT(*) FROM pragma_table_info('" + table + "') WHERE name = ?", column).Scan(&n)
	return n > 0, err
}

// seedTrunks ensures the one fixed top-level trunk (共享相册) and its built-in
// scattered-photo buckets exist. It is the only seeded root: the 隐私 trunk is
// personal, so it is created — and the legacy ownerless one claimed — by the
// first identity to register (see AuthIdentity). Trunks are the only roots;
// every user album is a flat child of one of them.
func (s *Store) seedTrunks() error {
	now := time.Now().Unix()

	// Legacy renames (idempotent): 私密相册 → 隐私, and the shared trunk's
	// own rename 相册 → 共享相册. Both are guarded so an upgraded library that
	// already holds the new name keeps the row it has.
	if _, err := s.db.Exec(`
		UPDATE albums SET name = '隐私'
		WHERE name = '私密相册' AND parent_id IS NULL
		  AND NOT EXISTS (SELECT 1 FROM albums WHERE name = '隐私' AND parent_id IS NULL)`); err != nil {
		return err
	}
	if _, err := s.db.Exec(`
		UPDATE albums SET name = '共享相册'
		WHERE name = '相册' AND parent_id IS NULL
		  AND NOT EXISTS (SELECT 1 FROM albums WHERE name = '共享相册' AND parent_id IS NULL)`); err != nil {
		return err
	}

	trunks := []struct {
		name   string
		hidden int64
	}{
		{"共享相册", 0},
	}
	for _, t := range trunks {
		if _, err := s.db.Exec(`
			INSERT INTO albums (name, parent_id, is_hidden, sync_mode, sort_order, created_at)
			SELECT ?, NULL, ?, 'backup', 0, ?
			WHERE NOT EXISTS (SELECT 1 FROM albums WHERE name = ? AND parent_id IS NULL)`,
			t.name, t.hidden, now, t.name); err != nil {
			return err
		}
	}

	// Built-in buckets: 收藏 (favorites) then the scattered "全部" bucket.
	buckets := []struct {
		name   string
		trunk  string
		hidden int64
	}{
		{"收藏", "共享相册", 0},
		{"散照", "共享相册", 0},
	}
	for _, b := range buckets {
		if _, err := s.db.Exec(`
			INSERT INTO albums (name, parent_id, is_hidden, sync_mode, sort_order, created_at)
			SELECT ?, (SELECT id FROM albums WHERE name = ? AND parent_id IS NULL), ?, 'backup', 0, ?
			WHERE EXISTS (SELECT 1 FROM albums WHERE name = ? AND parent_id IS NULL)
			  AND NOT EXISTS (
				SELECT 1 FROM albums
				WHERE name = ? AND parent_id = (SELECT id FROM albums WHERE name = ? AND parent_id IS NULL)
			  )`,
			b.name, b.trunk, b.hidden, now, b.trunk, b.name, b.trunk); err != nil {
			return err
		}
	}
	return nil
}

// pinIterations is the PBKDF2 cost for new PIN hashes. It is stored per row, so
// raising it later never invalidates an identity that registered earlier.
const pinIterations = 100000

// Identity is a family member. The PIN itself is never stored — only its
// PBKDF2 hash — and the name is unique: the first registration of a name fixes
// both the PIN and the 隐私 trunk that identity owns.
type Identity struct {
	ID        int64  `json:"id"`
	Name      string `json:"name"`
	CreatedAt int64  `json:"created_at"`
}

// ErrIdentityPIN 表示身份存在但 PIN 不匹配。
var ErrIdentityPIN = errors.New("identity PIN mismatch")

// hashPIN returns hex(PBKDF2-HMAC-SHA256(pin, salt, iterations, 32)).
func hashPIN(pin, saltHex string, iterations int) (string, error) {
	salt, err := hex.DecodeString(saltHex)
	if err != nil {
		return "", err
	}
	key, err := pbkdf2.Key(sha256.New, pin, salt, iterations, 32)
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(key), nil
}

// newSaltHex returns the hex of a fresh 16-byte salt.
func newSaltHex() (string, error) {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}

// verifyPIN checks a PIN against a stored hash in constant time, reporting
// ErrIdentityPIN when it does not match.
func verifyPIN(pin, saltHex, wantHash string, iterations int) error {
	got, err := hashPIN(pin, saltHex, iterations)
	if err != nil {
		return err
	}
	if subtle.ConstantTimeCompare([]byte(got), []byte(wantHash)) != 1 {
		return ErrIdentityPIN
	}
	return nil
}

// lookupIdentityTx reads one identity row by name, or ErrNotFound.
func lookupIdentityTx(ctx context.Context, tx *sql.Tx, name string) (Identity, string, string, int, error) {
	var ident Identity
	var salt, hash string
	var iterations int
	err := tx.QueryRowContext(ctx,
		`SELECT id, name, pin_salt, pin_hash, iterations, created_at FROM identities WHERE name = ?`, name).
		Scan(&ident.ID, &ident.Name, &salt, &hash, &iterations, &ident.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return Identity{}, "", "", 0, ErrNotFound
	}
	if err != nil {
		return Identity{}, "", "", 0, err
	}
	return ident, salt, hash, iterations, nil
}

// AuthIdentity resolves an identity by name. An unknown name registers with
// this PIN — 首次注册为准, so the PIN given here is the one that identity will
// keep — and is handed its 隐私 trunk in the same transaction. A known name is
// checked against the stored PIN and returns ErrIdentityPIN when it differs.
// registered reports whether this call created the identity.
func (s *Store) AuthIdentity(ctx context.Context, name, pin string) (Identity, bool, error) {
	name = strings.TrimSpace(name)
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Identity{}, false, err
	}
	defer tx.Rollback()

	ident, salt, hash, iterations, err := lookupIdentityTx(ctx, tx, name)
	if err == nil {
		if err := verifyPIN(pin, salt, hash, iterations); err != nil {
			return Identity{}, false, err
		}
		return ident, false, tx.Commit()
	}
	if !errors.Is(err, ErrNotFound) {
		return Identity{}, false, err
	}

	now := time.Now().Unix()
	salt, err = newSaltHex()
	if err != nil {
		return Identity{}, false, err
	}
	hash, err = hashPIN(pin, salt, pinIterations)
	if err != nil {
		return Identity{}, false, err
	}
	res, err := tx.ExecContext(ctx,
		`INSERT INTO identities (name, pin_salt, pin_hash, iterations, created_at) VALUES (?, ?, ?, ?, ?)`,
		name, salt, hash, pinIterations, now)
	if err != nil {
		// 同一名字被并发注册抢先：赢家的那一行才是这个身份，用本次 PIN 对它校验，
		// 而不是把这个请求也当成一次注册。
		winner, salt2, hash2, iterations2, lookErr := lookupIdentityTx(ctx, tx, name)
		if lookErr != nil {
			return Identity{}, false, err
		}
		if err := verifyPIN(pin, salt2, hash2, iterations2); err != nil {
			return Identity{}, false, err
		}
		return winner, false, tx.Commit()
	}
	id, err := res.LastInsertId()
	if err != nil {
		return Identity{}, false, err
	}
	if err := s.claimOrCreatePrivateTrunkTx(ctx, tx, id, now); err != nil {
		return Identity{}, false, err
	}
	if err := tx.Commit(); err != nil {
		return Identity{}, false, err
	}
	return Identity{ID: id, Name: name, CreatedAt: now}, true, nil
}

// SetIdentityPIN replaces an identity's PIN, checking the old one first. A new
// salt comes with it: the stored hash must not reveal that the PIN is unchanged.
func (s *Store) SetIdentityPIN(ctx context.Context, id int64, oldPIN, newPIN string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var salt, hash string
	var iterations int
	err = tx.QueryRowContext(ctx, `SELECT pin_salt, pin_hash, iterations FROM identities WHERE id = ?`, id).
		Scan(&salt, &hash, &iterations)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if err := verifyPIN(oldPIN, salt, hash, iterations); err != nil {
		return err
	}
	newSalt, err := newSaltHex()
	if err != nil {
		return err
	}
	newHash, err := hashPIN(newPIN, newSalt, pinIterations)
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx,
		`UPDATE identities SET pin_salt = ?, pin_hash = ?, iterations = ? WHERE id = ?`,
		newSalt, newHash, pinIterations, id); err != nil {
		return err
	}
	return tx.Commit()
}

// PrivateTrunkID returns the id of the identity's 隐私 trunk, or 0 when it owns
// none. A missing trunk is not an error: the caller only echoes it back.
func (s *Store) PrivateTrunkID(ctx context.Context, identityID int64) (int64, error) {
	var id int64
	err := s.db.QueryRowContext(ctx,
		`SELECT id FROM albums WHERE parent_id IS NULL AND name = ? AND owner_id = ?`,
		trunkPrivateName, identityID).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	return id, err
}

// SharedTrunkID returns the id of the top-level 共享相册 trunk, or 0 when the
// library has none.
func (s *Store) SharedTrunkID(ctx context.Context) (int64, error) {
	return trunkIDByName(ctx, s.db, trunkAlbumName)
}

// claimOrCreatePrivateTrunkTx hands a freshly registered identity its 隐私
// trunk. A legacy ownerless one is claimed whole — its sub-tree comes with it,
// because a 收藏 or 散照 bucket left at owner_id NULL would expose that
// identity's photos to the whole family. Otherwise a private trunk and its two
// built-in buckets are created.
func (s *Store) claimOrCreatePrivateTrunkTx(ctx context.Context, tx *sql.Tx, identityID, now int64) error {
	owner := identityID
	res, err := tx.ExecContext(ctx, `
		UPDATE albums SET owner_id = ?
		WHERE parent_id IS NULL AND is_hidden = 1 AND owner_id IS NULL AND name = ?`,
		identityID, trunkPrivateName)
	if err != nil {
		return err
	}
	claimed, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if claimed == 1 {
		trunkID, err := trunkIDByName(ctx, tx, trunkPrivateName)
		if err != nil {
			return err
		}
		ids, err := subtreeIDsTx(ctx, tx, trunkID)
		if err != nil {
			return err
		}
		ph, args := inArgs(ids)
		_, err = tx.ExecContext(ctx, `UPDATE albums SET owner_id = ? WHERE id IN (`+ph+`)`,
			append([]any{identityID}, args...)...)
		return err
	}

	trunkID, err := insertAlbumTx(ctx, tx, newAlbum{name: trunkPrivateName, hidden: 1, syncMode: "backup", ownerID: &owner}, now)
	if err != nil {
		return err
	}
	for _, name := range []string{favoriteAlbumName, "散照"} {
		if _, err := insertAlbumTx(ctx, tx, newAlbum{name: name, parentID: &trunkID, hidden: 1, syncMode: "backup", ownerID: &owner}, now); err != nil {
			return err
		}
	}
	return nil
}

// newAlbum is one album row to insert. ownerID is nil for a shared album (the
// whole family sees it) and the owning identity otherwise.
type newAlbum struct {
	name     string
	parentID *int64
	hidden   int64
	syncMode string
	ownerID  *int64
}

// insertAlbumTx inserts one album row and logs its creation.
func insertAlbumTx(ctx context.Context, tx *sql.Tx, a newAlbum, now int64) (int64, error) {
	res, err := tx.ExecContext(ctx,
		`INSERT INTO albums (name, parent_id, is_hidden, sync_mode, sort_order, created_at, owner_id)
		 VALUES (?, ?, ?, ?, 0, ?, ?)`,
		a.name, a.parentID, a.hidden, a.syncMode, now, a.ownerID)
	if err != nil {
		return 0, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, err
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO sync_log (entity, entity_id, op, at) VALUES ('album', ?, 'create', ?)`, id, now); err != nil {
		return 0, err
	}
	return id, nil
}

// trunkIDOfAlbumTx returns the trunk an album belongs to: a trunk is its own,
// a child album answers with its parent.
func trunkIDOfAlbumTx(ctx context.Context, tx *sql.Tx, albumID int64) (int64, error) {
	var id int64
	err := tx.QueryRowContext(ctx, `SELECT COALESCE(parent_id, id) FROM albums WHERE id = ?`, albumID).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNotFound
	}
	return id, err
}

// rowQuerier is the read side shared by *sql.DB and *sql.Tx.
type rowQuerier interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// trunkIDByName returns the id of the top-level trunk named `name`, or 0 when
// the library has none.
func trunkIDByName(ctx context.Context, q rowQuerier, name string) (int64, error) {
	var id int64
	err := q.QueryRowContext(ctx, `SELECT id FROM albums WHERE parent_id IS NULL AND name = ?`, name).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	return id, err
}

func (s *Store) Close() error { return s.db.Close() }

// ErrNotFound is returned by single-row lookups when no row matches.
var ErrNotFound = errors.New("not found")

// CreateAsset inserts an asset, upserting the blobs row and incrementing its
// ref_count within one transaction. It returns the new asset id.
func (s *Store) CreateAsset(ctx context.Context, a Asset) (int64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(ctx,
		`INSERT INTO blobs (hash, size, ref_count) VALUES (?, ?, 0)
		 ON CONFLICT(hash) DO NOTHING`, a.Hash, a.Size); err != nil {
		return 0, err
	}
	if _, err := tx.ExecContext(ctx,
		`UPDATE blobs SET ref_count = ref_count + 1 WHERE hash = ?`, a.Hash); err != nil {
		return 0, err
	}

	if a.Ext == "" {
		a.Ext = ExtensionOf(a.OriginalName)
	}

	res, err := tx.ExecContext(ctx,
		`INSERT INTO assets (hash, original_name, ext, media_type, mime_type, size, width, height, taken_at, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		a.Hash, a.OriginalName, a.Ext, a.MediaType, a.MimeType, a.Size, a.Width, a.Height, a.TakenAt, a.CreatedAt)
	if err != nil {
		return 0, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, err
	}

	if _, err := tx.ExecContext(ctx,
		`INSERT INTO sync_log (entity, entity_id, op, at) VALUES ('asset', ?, 'create', ?)`,
		id, a.CreatedAt); err != nil {
		return 0, err
	}

	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return id, nil
}

func (s *Store) GetAsset(ctx context.Context, id int64) (*Asset, error) {
	a, err := scanAsset(s.db.QueryRowContext(ctx, assetCols+" FROM assets WHERE id = ?", id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return a, err
}

// GetAssetVisible returns the asset only when this identity can see it: held by
// an album it can see, or sitting in the recycle bin of a trunk it can see.
// Every per-asset route goes through here, so an id belonging to someone else's
// 隐私相册 is indistinguishable from one that does not exist.
func (s *Store) GetAssetVisible(ctx context.Context, id, identityID int64) (*Asset, error) {
	a, err := scanAsset(s.db.QueryRowContext(ctx,
		assetCols+" FROM assets WHERE id = ? AND "+assetVisibleCond("assets.id"), id, identityID, identityID))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return a, err
}

func (s *Store) GetAssetByHash(ctx context.Context, hash string, identityID int64) (*Asset, bool, error) {
	a, err := scanAsset(s.db.QueryRowContext(ctx,
		assetCols+" FROM assets WHERE hash = ? AND "+assetVisibleCond("assets.id")+" ORDER BY id ASC LIMIT 1",
		hash, identityID, identityID))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	return a, true, nil
}

// The asset row's own name is the file's name; an album can keep its own
// (`album_assets.name`) when the clash rule had to number an arrival. Listings
// resolve the two, so a photo shows the name that album knows it by.
const (
	assetColsBeforeName = "id, hash"
	assetColsAfterName  = "ext, media_type, mime_type, size, width, height, taken_at, created_at, deleted_at, deleted_trunk_id, deleted_album_id"
	assetCols           = "SELECT " + assetColsBeforeName + ", original_name, " + assetColsAfterName
	// One album in view: the membership's own name, else the asset's.
	albumAssetName = "COALESCE((SELECT aa.name FROM album_assets aa WHERE aa.album_id = ? AND aa.asset_id = assets.id), original_name)"
	// A trunk aggregates its sub-albums, so the earliest membership inside this
	// trunk decides — that is the album the file was filed into first.
	trunkAssetName = "COALESCE((SELECT COALESCE(aa.name, assets.original_name) FROM album_assets aa JOIN albums al ON al.id = aa.album_id WHERE aa.asset_id = assets.id AND (al.id = ? OR al.parent_id = ?) ORDER BY aa.added_at ASC, aa.album_id ASC LIMIT 1), original_name)"
)

// visibleAlbumCond 是「这个身份能看到的相册」：没有主人的（全家共享）加上自己拥有的。
// 一个 ? —— 绑身份 id。
const visibleAlbumCond = "(owner_id IS NULL OR owner_id = ?)"

// assetVisibleCond 是「这个身份能看到的资材」：被一个可见相册收着，或者躺在某个可见主干的
// 回收站里（主干是删除时记下的）。两个 ? —— 都绑同一个身份 id。
func assetVisibleCond(idExpr string) string {
	return `(EXISTS (SELECT 1 FROM album_assets avaa JOIN albums aval ON aval.id = avaa.album_id
	                 WHERE avaa.asset_id = ` + idExpr + ` AND (aval.owner_id IS NULL OR aval.owner_id = ?))
	        OR EXISTS (SELECT 1 FROM assets avas JOIN albums avat ON avat.id = avas.deleted_trunk_id
	                 WHERE avas.id = ` + idExpr + ` AND (avat.owner_id IS NULL OR avat.owner_id = ?)))`
}

type rowScanner interface {
	Scan(dest ...any) error
}

func scanAsset(row rowScanner) (*Asset, error) {
	var a Asset
	if err := row.Scan(&a.ID, &a.Hash, &a.OriginalName, &a.Ext, &a.MediaType, &a.MimeType,
		&a.Size, &a.Width, &a.Height, &a.TakenAt, &a.CreatedAt,
		&a.DeletedAt, &a.DeletedTrunkID, &a.DeletedAlbumID); err != nil {
		return nil, err
	}
	return &a, nil
}

// ListAssets returns assets ordered by id DESC with cursor pagination.
// cursor is the base64-encoded last id of the previous page; empty means the
// first page. nextCursor is empty when no further assets remain.
func (s *Store) ListAssets(ctx context.Context, filter string, albumID *int64, cursor string, limit int, identityID int64) ([]Asset, string, error) {
	if limit <= 0 || limit > 1000 {
		limit = 100
	}
	lastID, err := decodeCursor(cursor)
	if err != nil {
		return nil, "", fmt.Errorf("bad cursor: %w", err)
	}

	var conds []string
	var args []any
	var nameArgs []any
	selectCols := assetCols
	switch filter {
	case "videos":
		conds = append(conds, "media_type = 'video'")
	default:
		conds = append(conds, "media_type IN ('image','video')")
	}
	// ListAssets is the active-asset listing; trashed assets live in the
	// recycle bin and are listed via ListTrash.
	conds = append(conds, "deleted_at IS NULL")
	// 可见性：只有被可见相册收着的资材才发给这个身份。
	conds = append(conds, "id IN (SELECT asset_id FROM album_assets WHERE album_id IN (SELECT id FROM albums WHERE "+visibleAlbumCond+"))")
	args = append(args, identityID)
	if albumID != nil {
		al, err := s.VisibleAlbum(ctx, *albumID, identityID)
		if err != nil {
			return nil, "", err
		}
		if al.ParentID == nil {
			// Trunk (共享相册/隐私 root): aggregate every descendant album's
			// members (built-in 散照/收藏 buckets plus user sub-albums), so a
			// single "全部" request returns 散照 + all sub-albums.
			conds = append(conds, "id IN (SELECT asset_id FROM album_assets WHERE album_id IN (SELECT id FROM albums WHERE parent_id = ?))")
			selectCols = "SELECT " + assetColsBeforeName + ", " + trunkAssetName + ", " + assetColsAfterName
			nameArgs = []any{*albumID, *albumID}
		} else {
			conds = append(conds, "id IN (SELECT asset_id FROM album_assets WHERE album_id = ?)")
			selectCols = "SELECT " + assetColsBeforeName + ", " + albumAssetName + ", " + assetColsAfterName
			nameArgs = []any{*albumID}
		}
		args = append(args, *albumID)
	}
	if lastID > 0 {
		conds = append(conds, "id < ?")
		args = append(args, lastID)
	}

	q := selectCols + " FROM assets"
	if len(conds) > 0 {
		q += " WHERE " + strings.Join(conds, " AND ")
	}
	q += " ORDER BY id DESC LIMIT " + strconv.Itoa(limit+1)

	rows, err := s.db.QueryContext(ctx, q, append(nameArgs, args...)...)
	if err != nil {
		return nil, "", err
	}
	defer rows.Close()

	assets := make([]Asset, 0)
	for rows.Next() {
		a, err := scanAsset(rows)
		if err != nil {
			return nil, "", err
		}
		assets = append(assets, *a)
	}
	if err := rows.Err(); err != nil {
		return nil, "", err
	}

	next := ""
	if len(assets) > limit {
		assets = assets[:limit]
		next = encodeCursor(assets[len(assets)-1].ID)
	}
	return assets, next, nil
}

// UpdateAssetName renames an asset's display name (original_name) and logs the
// change to sync_log. A manual rename is the user naming the file, so the
// per-album names the clash rule handed out are dropped with it — otherwise the
// album that had numbered the photo would keep showing the old name.
// It returns the updated asset.
func (s *Store) UpdateAssetName(ctx context.Context, id int64, name string) (*Asset, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx, `UPDATE assets SET original_name = ? WHERE id = ?`, name, id)
	if err != nil {
		return nil, err
	}
	if n, err := res.RowsAffected(); err != nil {
		return nil, err
	} else if n == 0 {
		return nil, ErrNotFound
	}
	if _, err := tx.ExecContext(ctx, `UPDATE album_assets SET name = NULL WHERE asset_id = ?`, id); err != nil {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO sync_log (entity, entity_id, op, at) VALUES ('asset', ?, 'update', ?)`,
		id, time.Now().Unix()); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return s.GetAsset(ctx, id)
}

// DeleteAsset permanently deletes the asset (trash-only path), decrements the
// blob ref_count, and deletes the blobs row when refs reach zero. It returns
// the affected blob hash and the ref count remaining after the decrement
// (0 means the caller should remove the physical blob file).
func (s *Store) DeleteAsset(ctx context.Context, id int64) (hash string, refsLeft int, err error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", 0, err
	}
	defer tx.Rollback()
	hash, refsLeft, err = s.deleteAssetRow(ctx, tx, id, time.Now().Unix())
	if err != nil {
		return "", 0, err
	}
	if err := tx.Commit(); err != nil {
		return "", 0, err
	}
	return hash, refsLeft, nil
}

// deleteAssetRow hard-deletes one asset row and decrements its blob ref count,
// deleting the blobs row when refs reach zero. It returns the affected blob
// hash and the ref count remaining (0 means delete the physical blob).
//
// Only a recycle-bin row can be destroyed: this is the irrecoverable path, so a
// live asset (deleted_at IS NULL) is refused rather than swept away by a
// misdirected id — everything the user can still see deletes through
// TrashAsset/RemoveOrTrash, which keep the 30-day window.
func (s *Store) deleteAssetRow(ctx context.Context, tx *sql.Tx, id int64, at int64) (string, int, error) {
	var h string
	err := tx.QueryRowContext(ctx, `SELECT hash FROM assets WHERE id = ? AND deleted_at IS NOT NULL`, id).Scan(&h)
	if errors.Is(err, sql.ErrNoRows) {
		return "", 0, ErrNotFound
	}
	if err != nil {
		return "", 0, err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM assets WHERE id = ?`, id); err != nil {
		return "", 0, err
	}
	var refs int
	if err := tx.QueryRowContext(ctx, `SELECT ref_count FROM blobs WHERE hash = ?`, h).Scan(&refs); err != nil {
		return "", 0, err
	}
	refs--
	if refs <= 0 {
		if _, err := tx.ExecContext(ctx, `DELETE FROM blobs WHERE hash = ?`, h); err != nil {
			return "", 0, err
		}
	} else {
		if _, err := tx.ExecContext(ctx, `UPDATE blobs SET ref_count = ? WHERE hash = ?`, refs, h); err != nil {
			return "", 0, err
		}
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO sync_log (entity, entity_id, op, at) VALUES ('asset', ?, 'delete', ?)`,
		id, at); err != nil {
		return "", 0, err
	}
	return h, refs, nil
}

// TrashAsset soft-deletes an active asset into the recycle bin: it records the
// time and its source album/trunk, drops its album memberships so active views
// and aggregates no longer include it, and logs an 'asset delete' change. The
// blob is kept so the photo can still be restored within 30 days.
func (s *Store) TrashAsset(ctx context.Context, id int64) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var exists int
	if err := tx.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM assets WHERE id = ? AND deleted_at IS NULL`, id).Scan(&exists); err != nil {
		return err
	}
	if exists == 0 {
		return ErrNotFound
	}

	origin, err := s.sourceAlbumTx(ctx, tx, id)
	if err != nil {
		return err
	}
	if err := s.trashAssetTx(ctx, tx, id, origin, time.Now().Unix()); err != nil {
		return err
	}
	return tx.Commit()
}

// trashAssetTx soft-deletes one active asset inside a caller's transaction.
// `origin` is what the restore path reads back: where it was, and the name it
// showed under there — the album may not outlive the photo (deleting an album
// trashes what it held) and an album may have numbered the photo's name.
func (s *Store) trashAssetTx(ctx context.Context, tx *sql.Tx, id int64, origin trashOrigin, at int64) error {
	var albumName, assetName any
	if origin.albumName != "" {
		albumName = origin.albumName
	}
	if origin.assetName != "" {
		assetName = origin.assetName
	}
	if _, err := tx.ExecContext(ctx,
		`UPDATE assets SET deleted_at = ?, deleted_trunk_id = ?, deleted_album_id = ?, deleted_album_name = ?, deleted_name = ? WHERE id = ?`,
		at, origin.trunkID, origin.albumID, albumName, assetName, id); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM album_assets WHERE asset_id = ?`, id); err != nil {
		return err
	}
	_, err := tx.ExecContext(ctx,
		`INSERT INTO sync_log (entity, entity_id, op, at) VALUES ('asset', ?, 'delete', ?)`,
		id, at)
	return err
}

// RestoreAsset returns a trashed asset to the active set, re-adding it to the
// album it was deleted from. That album may itself have been deleted (deleting
// an album trashes what it held), in which case the recorded name is used to
// rebuild it under the same trunk — restoring two photos of one deleted album
// lands them in the same rebuilt album, not in two. Only when there is nothing
// to rebuild from does the photo fall back to the trunk's 散照 bucket.
func (s *Store) RestoreAsset(ctx context.Context, id int64) (*Asset, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	var trunkID, albumID *int64
	var albumName, deletedName *string
	err = tx.QueryRowContext(ctx,
		`SELECT deleted_trunk_id, deleted_album_id, deleted_album_name, deleted_name FROM assets WHERE id = ? AND deleted_at IS NOT NULL`,
		id).Scan(&trunkID, &albumID, &albumName, &deletedName)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}

	now := time.Now().Unix()
	if _, err := tx.ExecContext(ctx,
		`UPDATE assets SET deleted_at = NULL, deleted_trunk_id = NULL, deleted_album_id = NULL, deleted_album_name = NULL, deleted_name = NULL WHERE id = ?`,
		id); err != nil {
		return nil, err
	}

	targetID := int64(0)
	if albumID != nil && *albumID > 0 {
		var exists int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM albums WHERE id = ?`, *albumID).Scan(&exists); err != nil {
			return nil, err
		}
		if exists > 0 {
			targetID = *albumID
		}
	}
	if targetID == 0 && albumName != nil && *albumName != "" && trunkID != nil && *trunkID > 0 {
		targetID, err = s.childAlbumTx(ctx, tx, *trunkID, *albumName, now)
		if err != nil {
			return nil, err
		}
	}
	if targetID == 0 && trunkID != nil && *trunkID > 0 {
		sid, err := s.scatterBucketTx(ctx, tx, *trunkID)
		if err != nil {
			return nil, err
		}
		if sid > 0 {
			targetID = sid
		}
	}
	if targetID > 0 {
		// 名字回到它删除时在这个相册里的样子；若那个名字现在被这个相册里的别的
		// 文件占了（删除期间新放进来的），重新编号——恢复不该制造重名。
		var own string
		if err := tx.QueryRowContext(ctx, `SELECT original_name FROM assets WHERE id = ?`, id).Scan(&own); err != nil {
			return nil, err
		}
		want := own
		if deletedName != nil && *deletedName != "" {
			want = *deletedName
		}
		if clashID, _, _, err := albumNameClashTx(ctx, tx, targetID, want, id); err != nil {
			return nil, err
		} else if clashID > 0 {
			if want, err = freeNameInAlbumTx(ctx, tx, targetID, want); err != nil {
				return nil, err
			}
		}
		var membershipName any
		if want != own {
			membershipName = want
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT OR IGNORE INTO album_assets (album_id, asset_id, added_at, name) VALUES (?, ?, ?, ?)`,
			targetID, id, now, membershipName); err != nil {
			return nil, err
		}
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO sync_log (entity, entity_id, op, at) VALUES ('asset', ?, 'create', ?)`,
		id, now); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return s.GetAsset(ctx, id)
}

// ListTrash returns recycle-bin assets (deleted_at IS NOT NULL), optionally
// filtered to one trunk, ordered by id DESC with cursor pagination.
func (s *Store) ListTrash(ctx context.Context, trunkID *int64, cursor string, limit int, identityID int64) ([]Asset, string, error) {
	if limit <= 0 || limit > 1000 {
		limit = 100
	}
	lastID, err := decodeCursor(cursor)
	if err != nil {
		return nil, "", fmt.Errorf("bad cursor: %w", err)
	}
	conds := []string{"deleted_at IS NOT NULL"}
	var args []any
	if trunkID != nil {
		if _, err := s.VisibleAlbum(ctx, *trunkID, identityID); err != nil {
			return nil, "", err
		}
		conds = append(conds, "deleted_trunk_id = ?")
		args = append(args, *trunkID)
	} else {
		conds = append(conds, "deleted_trunk_id IN (SELECT id FROM albums WHERE "+visibleAlbumCond+")")
		args = append(args, identityID)
	}
	if lastID > 0 {
		conds = append(conds, "id < ?")
		args = append(args, lastID)
	}
	q := assetCols + " FROM assets WHERE " + strings.Join(conds, " AND ") + " ORDER BY id DESC LIMIT " + strconv.Itoa(limit+1)
	rows, err := s.db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, "", err
	}
	defer rows.Close()
	assets := make([]Asset, 0)
	for rows.Next() {
		a, err := scanAsset(rows)
		if err != nil {
			return nil, "", err
		}
		assets = append(assets, *a)
	}
	if err := rows.Err(); err != nil {
		return nil, "", err
	}
	next := ""
	if len(assets) > limit {
		assets = assets[:limit]
		next = encodeCursor(assets[len(assets)-1].ID)
	}
	return assets, next, nil
}

// ClearTrash permanently deletes every trashed asset (optionally one trunk),
// returning the blob hashes whose ref counts reached zero so the caller can
// remove the physical files and thumbnails.
func (s *Store) ClearTrash(ctx context.Context, trunkID *int64, identityID int64) ([]string, error) {
	if trunkID != nil {
		if _, err := s.VisibleAlbum(ctx, *trunkID, identityID); err != nil {
			return nil, err
		}
	}
	return s.deleteTrashWhere(ctx, func(where string, args []any) (string, []any) {
		if trunkID != nil {
			where += " AND deleted_trunk_id = ?"
			args = append(args, *trunkID)
		}
		return where, args
	})
}

// PurgeExpiredTrash permanently deletes trashed assets older than `before` and
// returns blob hashes whose ref counts reached zero.
func (s *Store) PurgeExpiredTrash(ctx context.Context, before int64) ([]string, error) {
	return s.deleteTrashWhere(ctx, func(where string, args []any) (string, []any) {
		where += " AND deleted_at < ?"
		args = append(args, before)
		return where, args
	})
}

func (s *Store) deleteTrashWhere(ctx context.Context, addCond func(string, []any) (string, []any)) ([]string, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	where, args := addCond("deleted_at IS NOT NULL", nil)
	rows, err := tx.QueryContext(ctx, `SELECT id FROM assets WHERE `+where, args...)
	if err != nil {
		return nil, err
	}
	var ids []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, err
		}
		ids = append(ids, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	var toDelete []string
	now := time.Now().Unix()
	for _, id := range ids {
		h, refs, err := s.deleteAssetRow(ctx, tx, id, now)
		if err != nil {
			return nil, err
		}
		if refs <= 0 {
			toDelete = append(toDelete, h)
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return toDelete, nil
}

// trashOrigin is where a photo was when it was trashed: the trunk and album the
// recycle bin records for provenance, the album's name (so a deleted album can
// be rebuilt on restore) and the name the photo displayed under inside that
// album — which the album may have numbered to avoid a clash.
type trashOrigin struct {
	trunkID   *int64
	albumID   *int64
	albumName string
	assetName string
}

// sourceAlbumTx picks the album the asset is most meaningfully "in" for trash
// provenance: the smallest-id non-收藏 album (用户相册 or 散照 bucket), falling
// back to 收藏 if that's all it has, else the 相册 trunk. The album's name and
// the photo's name inside it come back with it, so a restore can rebuild both
// once the rows are gone.
func (s *Store) sourceAlbumTx(ctx context.Context, tx *sql.Tx, assetID int64) (trashOrigin, error) {
	rows, err := tx.QueryContext(ctx, `
		SELECT a.id, a.parent_id, a.name, COALESCE(aa.name, ast.original_name) FROM albums a
		JOIN album_assets aa ON aa.album_id = a.id
		JOIN assets ast ON ast.id = aa.asset_id
		WHERE aa.asset_id = ?
		ORDER BY (a.name = '收藏') ASC, a.id ASC`, assetID)
	if err != nil {
		return trashOrigin{}, err
	}
	defer rows.Close()
	var origin trashOrigin
	var albumID int64
	var parentID *int64
	found := false
	for rows.Next() {
		var pid *int64
		if err := rows.Scan(&albumID, &pid, &origin.albumName, &origin.assetName); err != nil {
			return trashOrigin{}, err
		}
		parentID = pid
		found = true
		break
	}
	if err := rows.Err(); err != nil {
		return trashOrigin{}, err
	}
	if !found {
		tid, err := trunkIDByName(ctx, tx, trunkAlbumName)
		if err != nil {
			return trashOrigin{}, err
		}
		return trashOrigin{trunkID: &tid}, nil
	}
	if parentID == nil {
		origin.trunkID = &albumID
	} else {
		origin.trunkID = parentID
	}
	origin.albumID = &albumID
	return origin, nil
}

func (s *Store) scatterBucketTx(ctx context.Context, tx *sql.Tx, trunkID int64) (int64, error) {
	for _, name := range []string{"散照", "未分类散照"} {
		var id int64
		err := tx.QueryRowContext(ctx, `SELECT id FROM albums WHERE parent_id = ? AND name = ?`, trunkID, name).Scan(&id)
		if err == nil {
			return id, nil
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return 0, err
		}
	}
	return 0, nil
}

// CreateAlbum creates an album under `parentID`, or as a new root when it is
// nil. A child inherits its parent's owner — filed under a 隐私 trunk it is that
// identity's alone, filed under the shared trunk it belongs to the family — so
// the parent has to be one the caller can see.
func (s *Store) CreateAlbum(ctx context.Context, name string, parentID *int64, isHidden bool, syncMode string, identityID int64) (int64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()

	var ownerID *int64
	if parentID != nil {
		parent, err := visibleAlbum(ctx, tx, *parentID, identityID)
		if err != nil {
			return 0, err
		}
		ownerID = parent.OwnerID
	}
	hidden := int64(0)
	if isHidden {
		hidden = 1
	}
	id, err := insertAlbumTx(ctx, tx, newAlbum{
		name:     name,
		parentID: parentID,
		hidden:   hidden,
		syncMode: syncMode,
		ownerID:  ownerID,
	}, time.Now().Unix())
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return id, nil
}

func (s *Store) GetAlbum(ctx context.Context, id int64) (*Album, error) {
	al, err := scanAlbum(s.db.QueryRowContext(ctx, albumCols+" FROM albums WHERE id = ?", id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return al, err
}

// VisibleAlbum returns the album only when this identity can see it — a shared
// album, or one of its own. An album someone else owns is ErrNotFound, exactly
// like one that does not exist.
func (s *Store) VisibleAlbum(ctx context.Context, id, identityID int64) (*Album, error) {
	return visibleAlbum(ctx, s.db, id, identityID)
}

// visibleAlbum is VisibleAlbum over any queryer. Callers inside an open
// transaction must pass their *sql.Tx: the store runs on a single connection, so
// reading through the pool while a transaction holds it would wait forever.
func visibleAlbum(ctx context.Context, q rowQuerier, id, identityID int64) (*Album, error) {
	al, err := scanAlbum(q.QueryRowContext(ctx, albumCols+" FROM albums WHERE id = ? AND "+visibleAlbumCond, id, identityID))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return al, err
}

// ListAlbums returns the albums this identity can see: the shared ones plus its
// own 隐私 sub-tree.
func (s *Store) ListAlbums(ctx context.Context, identityID int64) ([]Album, error) {
	rows, err := s.db.QueryContext(ctx,
		albumCols+" FROM albums WHERE "+visibleAlbumCond+" ORDER BY parent_id, sort_order, name", identityID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	albums := make([]Album, 0)
	for rows.Next() {
		al, err := scanAlbum(rows)
		if err != nil {
			return nil, err
		}
		albums = append(albums, *al)
	}
	return albums, rows.Err()
}

const albumCols = "SELECT id, name, parent_id, is_hidden, sync_mode, sort_order, created_at, owner_id"

func scanAlbum(row rowScanner) (*Album, error) {
	var al Album
	if err := row.Scan(&al.ID, &al.Name, &al.ParentID, &al.IsHidden, &al.SyncMode, &al.SortOrder, &al.CreatedAt, &al.OwnerID); err != nil {
		return nil, err
	}
	return &al, nil
}

// AlbumPatch holds the fields an UpdateAlbum call may modify. Nil fields are
// left untouched; a non-nil ParentID of 0 clears the parent (moves to root).
type AlbumPatch struct {
	Name      *string
	ParentID  *int64
	IsHidden  *int64
	SyncMode  *string
	SortOrder *int64
}

func (s *Store) UpdateAlbum(ctx context.Context, id int64, p AlbumPatch) (*Album, error) {
	var sets []string
	var args []any

	if p.Name != nil {
		sets = append(sets, "name = ?")
		args = append(args, *p.Name)
	}
	if p.ParentID != nil {
		if *p.ParentID == 0 {
			sets = append(sets, "parent_id = NULL")
		} else {
			sets = append(sets, "parent_id = ?")
			args = append(args, *p.ParentID)
		}
	}
	if p.IsHidden != nil {
		sets = append(sets, "is_hidden = ?")
		args = append(args, *p.IsHidden)
	}
	if p.SyncMode != nil {
		sets = append(sets, "sync_mode = ?")
		args = append(args, *p.SyncMode)
	}
	if p.SortOrder != nil {
		sets = append(sets, "sort_order = ?")
		args = append(args, *p.SortOrder)
	}

	if len(sets) == 0 {
		return s.GetAlbum(ctx, id)
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	args = append(args, id)
	if _, err := tx.ExecContext(ctx, "UPDATE albums SET "+strings.Join(sets, ", ")+" WHERE id = ?", args...); err != nil {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO sync_log (entity, entity_id, op, at) VALUES ('album', ?, 'update', ?)`,
		id, time.Now().Unix()); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return s.GetAlbum(ctx, id)
}

// DeleteAlbum removes an album and, with it, its whole sub-album sub-tree (the
// parent_id cascade). The photos are not lost with it: every member that nothing
// outside the sub-tree holds goes into the recycle bin in the same transaction,
// carrying the deleted album's name, so a restore within the 30-day window
// rebuilds the album instead of dropping the photo into 散照. A photo shared
// with an album outside the sub-tree is left alone — it stays reachable there.
// Each album row the cascade takes is logged, so a cursor sees the children go
// too rather than just the one id the client asked to delete.
func (s *Store) DeleteAlbum(ctx context.Context, id int64) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var name string
	var parentID *int64
	err = tx.QueryRowContext(ctx, `SELECT name, parent_id FROM albums WHERE id = ?`, id).Scan(&name, &parentID)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}

	ids, err := subtreeIDsTx(ctx, tx, id)
	if err != nil {
		return err
	}
	members, err := orphanedMembersTx(ctx, tx, ids)
	if err != nil {
		return err
	}

	// Provenance for the trashed photos: the sub-album's trunk and the album's
	// own name. Deleting a trunk root (the client never offers it) has no parent
	// to rebuild under, so its photos stay nameless and restore to 散照. The
	// per-album name is deliberately not carried over: the album goes away with
	// it, so the photos come back under their own names (renumbered if the
	// rebuilt album already holds a name).
	at := time.Now().Unix()
	trunkID := id
	var albumID *int64
	var albumName string
	if parentID != nil {
		trunkID = *parentID
		albumID = &id
		albumName = name
	}
	for _, member := range members {
		origin := trashOrigin{trunkID: &trunkID, albumID: albumID, albumName: albumName}
		if err := s.trashAssetTx(ctx, tx, member, origin, at); err != nil {
			return err
		}
	}

	res, err := tx.ExecContext(ctx, `DELETE FROM albums WHERE id = ?`, id)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	for _, gone := range ids {
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO sync_log (entity, entity_id, op, at) VALUES ('album', ?, 'delete', ?)`,
			gone, at); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// subtreeIDsTx returns `root` plus every album below it.
func subtreeIDsTx(ctx context.Context, tx *sql.Tx, root int64) ([]int64, error) {
	rows, err := tx.QueryContext(ctx, `
		WITH RECURSIVE sub(id) AS (
			SELECT id FROM albums WHERE id = ?
			UNION ALL
			SELECT a.id FROM albums a JOIN sub ON a.parent_id = sub.id
		)
		SELECT id FROM sub`, root)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// orphanedMembersTx returns the active assets that only the albums in `ids` hold
// — exactly the ones a delete of that sub-tree would leave unreachable: not in
// any album, so absent from every aggregate, and not in the bin either.
func orphanedMembersTx(ctx context.Context, tx *sql.Tx, ids []int64) ([]int64, error) {
	if len(ids) == 0 {
		return nil, nil
	}
	ph, args := inArgs(ids)
	rows, err := tx.QueryContext(ctx, `
		SELECT DISTINCT aa.asset_id FROM album_assets aa
		JOIN assets a ON a.id = aa.asset_id
		WHERE aa.album_id IN (`+ph+`)
		  AND a.deleted_at IS NULL
		  AND NOT EXISTS (
			SELECT 1 FROM album_assets other
			WHERE other.asset_id = aa.asset_id AND other.album_id NOT IN (`+ph+`)
		  )`, append(args, args...)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// inArgs renders the placeholders and arguments for an IN (…) clause.
func inArgs(ids []int64) (string, []any) {
	ph := make([]string, len(ids))
	args := make([]any, len(ids))
	for i, id := range ids {
		ph[i] = "?"
		args[i] = id
	}
	return strings.Join(ph, ","), args
}

// childAlbumTx finds the child of `trunkID` named `name`, creating it (hidden
// like its trunk) when it is missing: the restore path rebuilding an album that
// was deleted. An album the user already re-created under that name is reused,
// so two restored photos never end up in two albums.
func (s *Store) childAlbumTx(ctx context.Context, tx *sql.Tx, trunkID int64, name string, now int64) (int64, error) {
	var id int64
	err := tx.QueryRowContext(ctx, `SELECT id FROM albums WHERE parent_id = ? AND name = ?`, trunkID, name).Scan(&id)
	if err == nil {
		return id, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return 0, err
	}
	// 子相册跟着主干走：隐私主干下重建出来的相册仍归同一个人，否则一次恢复就会把
	// 这张照片放进全家可见的地方。
	var hidden int64
	var ownerID *int64
	if err := tx.QueryRowContext(ctx, `SELECT is_hidden, owner_id FROM albums WHERE id = ?`, trunkID).Scan(&hidden, &ownerID); err != nil {
		return 0, err
	}
	return insertAlbumTx(ctx, tx, newAlbum{
		name:     name,
		parentID: &trunkID,
		hidden:   hidden,
		syncMode: "backup",
		ownerID:  ownerID,
	}, now)
}

// ErrCycle 表示一次移动会把相册放到它自己或它的某个后代之下。
var ErrCycle = errors.New("cannot move album into itself")

// MoveAlbum 迁移相册。若目标层级已存在同名相册则改为合并：资产关联并过去、
// 直接子相册改挂到幸存者、源行删除——全部在一个事务里完成，多设备游标因此
// 永远看不到迁移到一半的树。parentID 为 nil 表示移到主干层级；否则相册继承
// 新父级的 hidden 状态（主干层级可见，所以移到根会清掉 hidden）。
// MoveAlbum 迁移相册。若目标层级已存在同名相册则改为合并：资产关联并过去、
// 直接子相册改挂到幸存者、源行删除——全部在一个事务里完成，多设备游标因此
// 永远看不到迁移到一半的树。parentID 为 nil 表示移到主干层级；否则相册继承
// 新父级的 hidden 状态（主干层级可见，所以移到根会清掉 hidden）。
// 相册跟着落点改归谁：搬到根成为全家的，搬进自己的隐私主干就只有自己可见。
// 源相册与目标父级都必须是这个身份看得见的。
// 返回幸存相册、发生合并时的目标 id、以及合并真正新增的资产关联条数。
func (s *Store) MoveAlbum(ctx context.Context, id int64, parentID *int64, identityID int64) (*Album, *int64, int, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, nil, 0, err
	}
	defer tx.Rollback()

	src, err := scanAlbum(tx.QueryRowContext(ctx, albumCols+" FROM albums WHERE id = ? AND "+visibleAlbumCond, id, identityID))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil, 0, ErrNotFound
	}
	if err != nil {
		return nil, nil, 0, err
	}

	var ownerID *int64
	hidden := int64(0)
	if parentID != nil {
		if err := tx.QueryRowContext(ctx, `SELECT is_hidden, owner_id FROM albums WHERE id = ? AND `+visibleAlbumCond, *parentID, identityID).Scan(&hidden, &ownerID); errors.Is(err, sql.ErrNoRows) {
			return nil, nil, 0, ErrNotFound
		} else if err != nil {
			return nil, nil, 0, err
		}
		// 从目标向上爬链，顺带覆盖「目标就是相册自己」这种情况。
		cur := *parentID
		for {
			if cur == id {
				return nil, nil, 0, ErrCycle
			}
			var next *int64
			if err := tx.QueryRowContext(ctx, `SELECT parent_id FROM albums WHERE id = ?`, cur).Scan(&next); err != nil || next == nil {
				break // 走到顶层（或数据异常），不可能成环
			}
			cur = *next
		}
	}

	now := time.Now().Unix()
	// Root-level merges exclude the trunks: they are the library itself, so an
	// album moved to the top level must never be folded into one — that would
	// pour its photos into the trunk row and delete the album being moved.
	mergeQ := `SELECT id FROM albums WHERE parent_id IS NULL AND name = ? AND id <> ? AND name NOT IN (?, ?)`
	mergeArgs := []any{src.Name, id, trunkAlbumName, trunkPrivateName}
	if parentID != nil {
		mergeQ = `SELECT id FROM albums WHERE parent_id = ? AND name = ? AND id <> ?`
		mergeArgs = []any{*parentID, src.Name, id}
	}
	var targetID int64
	mergeErr := tx.QueryRowContext(ctx, mergeQ, mergeArgs...).Scan(&targetID)
	if mergeErr != nil && !errors.Is(mergeErr, sql.ErrNoRows) {
		return nil, nil, 0, mergeErr
	}

	if errors.Is(mergeErr, sql.ErrNoRows) {
		if _, err := tx.ExecContext(ctx,
			`UPDATE albums SET parent_id = ?, is_hidden = ?, owner_id = ? WHERE id = ?`, parentID, hidden, ownerID, id); err != nil {
			return nil, nil, 0, err
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO sync_log (entity, entity_id, op, at) VALUES ('album', ?, 'update', ?)`, id, now); err != nil {
			return nil, nil, 0, err
		}
		if err := tx.Commit(); err != nil {
			return nil, nil, 0, err
		}
		al, err := s.GetAlbum(ctx, id)
		return al, nil, 0, err
	}

	// 合并：幸存者保留自己的行，因此用它的资产集合判断哪些资产是真正新增的
	// （只有新增的才值得写 sync_log）。
	inTarget := map[int64]struct{}{}
	exRows, err := tx.QueryContext(ctx, `SELECT asset_id FROM album_assets WHERE album_id = ?`, targetID)
	if err != nil {
		return nil, nil, 0, err
	}
	for exRows.Next() {
		var aid int64
		if err := exRows.Scan(&aid); err != nil {
			exRows.Close()
			return nil, nil, 0, err
		}
		inTarget[aid] = struct{}{}
	}
	err = exRows.Err()
	exRows.Close()
	if err != nil {
		return nil, nil, 0, err
	}

	var added []int64
	srcRows, err := tx.QueryContext(ctx, `SELECT asset_id FROM album_assets WHERE album_id = ?`, id)
	if err != nil {
		return nil, nil, 0, err
	}
	for srcRows.Next() {
		var aid int64
		if err := srcRows.Scan(&aid); err != nil {
			srcRows.Close()
			return nil, nil, 0, err
		}
		added = append(added, aid)
	}
	err = srcRows.Err()
	srcRows.Close()
	if err != nil {
		return nil, nil, 0, err
	}

	res, err := tx.ExecContext(ctx, `
		INSERT OR IGNORE INTO album_assets (album_id, asset_id, added_at, name)
		SELECT ?, asset_id, added_at, name FROM album_assets WHERE album_id = ?`, targetID, id)
	if err != nil {
		return nil, nil, 0, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return nil, nil, 0, err
	}
	moved := int(n)

	// 合并进来的资产若与幸存者里同名（且内容不同）的撞名，按「后进加序号」处理：
	// 先到的那个保留原名，改的是刚搬进来的这一份的**相册内名字**。已经在幸存者
	// 里的（inTarget）不算后进，不动。
	for _, aid := range added {
		if _, existing := inTarget[aid]; existing {
			continue
		}
		var name, hash string
		if err := tx.QueryRowContext(ctx, `
			SELECT COALESCE(aa.name, a.original_name), a.hash FROM album_assets aa
			JOIN assets a ON a.id = aa.asset_id
			WHERE aa.album_id = ? AND aa.asset_id = ?`, targetID, aid).Scan(&name, &hash); err != nil {
			return nil, nil, 0, err
		}
		clashID, clashHash, _, err := albumNameClashTx(ctx, tx, targetID, name, aid)
		if err != nil {
			return nil, nil, 0, err
		}
		if clashID == 0 || clashHash == hash {
			// 名字没人用，或撞上的是同一份内容：保留原样。同一份字节在同一个相册里
			// 有两条记录只可能来自绕开客户端去重的直接上传；宁可留两条，也不在这里
			// 删行——那会把可能还属于第三个相册的那一行变成孤儿。
			continue
		}
		numbered, err := freeNameInAlbumTx(ctx, tx, targetID, name)
		if err != nil {
			return nil, nil, 0, err
		}
		if _, err := tx.ExecContext(ctx,
			`UPDATE album_assets SET name = ? WHERE album_id = ? AND asset_id = ?`,
			numbered, targetID, aid); err != nil {
			return nil, nil, 0, err
		}
	}

	// 子相册先记下来，改挂到幸存者后再删源行（源行的旧关联靠外键级联清掉）。
	childRows, err := tx.QueryContext(ctx, `SELECT id FROM albums WHERE parent_id = ?`, id)
	if err != nil {
		return nil, nil, 0, err
	}
	var childIDs []int64
	for childRows.Next() {
		var cid int64
		if err := childRows.Scan(&cid); err != nil {
			childRows.Close()
			return nil, nil, 0, err
		}
		childIDs = append(childIDs, cid)
	}
	err = childRows.Err()
	childRows.Close()
	if err != nil {
		return nil, nil, 0, err
	}

	if _, err := tx.ExecContext(ctx, `UPDATE albums SET parent_id = ? WHERE parent_id = ?`, targetID, id); err != nil {
		return nil, nil, 0, err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM albums WHERE id = ?`, id); err != nil {
		return nil, nil, 0, err
	}

	if _, err := tx.ExecContext(ctx,
		`INSERT INTO sync_log (entity, entity_id, op, at) VALUES ('album', ?, 'update', ?)`, targetID, now); err != nil {
		return nil, nil, 0, err
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO sync_log (entity, entity_id, op, at) VALUES ('album', ?, 'delete', ?)`, id, now); err != nil {
		return nil, nil, 0, err
	}
	for _, cid := range childIDs {
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO sync_log (entity, entity_id, op, at) VALUES ('album', ?, 'update', ?)`, cid, now); err != nil {
			return nil, nil, 0, err
		}
	}
	for _, aid := range added {
		if _, ok := inTarget[aid]; ok {
			continue
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO sync_log (entity, entity_id, op, at) VALUES ('album_asset', ?, 'create', ?)`, aid, now); err != nil {
			return nil, nil, 0, err
		}
	}

	if err := tx.Commit(); err != nil {
		return nil, nil, 0, err
	}
	al, err := s.GetAlbum(ctx, targetID)
	return al, &targetID, moved, err
}

// AddAssetToAlbum is idempotent. What arrives is checked against the album
// before it is linked: these very bytes already there (same hash, whatever name
// they are kept under) mean the newcomer is a duplicate and is not added at all;
// the same name on different bytes means the newcomer gets numbered — "x.jpg"
// arriving beside an existing "x.jpg" becomes "x (1).jpg". The newcomer is the
// one that moves: the file already in the album keeps the name the user knows
// it by.
//
// onlyHere is 转到隐私相册: before the photo is filed, every reference it has in
// a *shared* album (owner_id IS NULL) is detached, so "only I can see it" is the
// server's guarantee and not the client's good manners. Another identity's 隐私
// album is never touched — the detach matches shared albums only. The number of
// shared references detached comes back to the caller.
func (s *Store) AddAssetToAlbum(ctx context.Context, albumID, assetID, identityID int64, onlyHere bool) (int, error) {
	// 目标相册与这张照片都必须是这个身份看得见的，否则与不存在同解。
	if _, err := s.VisibleAlbum(ctx, albumID, identityID); err != nil {
		return 0, err
	}
	if _, err := s.GetAssetVisible(ctx, assetID, identityID); err != nil {
		return 0, err
	}

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()

	now := time.Now().Unix()
	detached := 0
	if onlyHere {
		res, err := tx.ExecContext(ctx, `
			DELETE FROM album_assets WHERE asset_id = ?
			  AND album_id IN (SELECT id FROM albums WHERE owner_id IS NULL)`, assetID)
		if err != nil {
			return 0, err
		}
		n, err := res.RowsAffected()
		if err != nil {
			return 0, err
		}
		detached = int(n)
		if detached > 0 {
			if _, err := tx.ExecContext(ctx,
				`INSERT INTO sync_log (entity, entity_id, op, at) VALUES ('album_asset', ?, 'delete', ?)`,
				assetID, now); err != nil {
				return 0, err
			}
		}
	}

	var ownName, ownHash string
	err = tx.QueryRowContext(ctx, `SELECT original_name, hash FROM assets WHERE id = ?`, assetID).Scan(&ownName, &ownHash)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNotFound
	}
	if err != nil {
		return 0, err
	}

	// 内容先说话：同一份字节在一个相册里只留一条，名字不影响这个判断。
	if _, _, found, err := albumHashTx(ctx, tx, albumID, ownHash, assetID); err != nil {
		return 0, err
	} else if found {
		return detached, tx.Commit()
	}

	// 同名但不是同一份内容：给**这一份在这个相册里的名字**加编号。名字记在成员
	// 关系上，所以同一个资产在别的相册里仍叫它原来的名字。
	membershipName, err := membershipNameTx(ctx, tx, albumID, ownName, assetID)
	if err != nil {
		return 0, err
	}

	res, err := tx.ExecContext(ctx,
		`INSERT OR IGNORE INTO album_assets (album_id, asset_id, added_at, name) VALUES (?, ?, ?, ?)`,
		albumID, assetID, now, membershipName)
	if err != nil {
		return 0, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, err
	}
	if n == 0 {
		// 本来就在这个相册里：成员关系与它的名字都不动。
		return detached, tx.Commit()
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO sync_log (entity, entity_id, op, at) VALUES ('album_asset', ?, 'create', ?)`,
		assetID, now); err != nil {
		return 0, err
	}
	return detached, tx.Commit()
}

// membershipNameTx picks the name a new membership should carry: NULL when the
// asset's own name is free in that album (the normal case — the membership
// inherits it), otherwise the numbered "x (1).ext" form.
func membershipNameTx(ctx context.Context, tx *sql.Tx, albumID int64, name string, assetID int64) (any, error) {
	clashID, _, _, err := albumNameClashTx(ctx, tx, albumID, name, assetID)
	if err != nil {
		return nil, err
	}
	if clashID == 0 {
		return nil, nil
	}
	return freeNameInAlbumTx(ctx, tx, albumID, name)
}

// NameInAlbum decides what a file arriving in `albumID` is called before it is
// stored. The content speaks first: if the album already holds these very bytes,
// their asset id comes back (under whatever name they are kept there) and the
// caller links that copy instead of storing a second one. Otherwise a free name
// passes through, and a name already held by something else comes back numbered.
func (s *Store) NameInAlbum(ctx context.Context, albumID int64, hash, name string) (string, int64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return "", 0, err
	}
	defer tx.Rollback()

	if id, stored, found, err := albumHashTx(ctx, tx, albumID, hash, 0); err != nil {
		return "", 0, err
	} else if found {
		return stored, id, nil
	}
	clashID, _, _, err := albumNameClashTx(ctx, tx, albumID, name, 0)
	if err != nil {
		return "", 0, err
	}
	if clashID == 0 {
		return name, 0, nil
	}
	numbered, err := freeNameInAlbumTx(ctx, tx, albumID, name)
	return numbered, 0, err
}

// albumHashTx finds the album member holding `hash`, ignoring `except`: the same
// bytes belong in an album once, whatever name they ended up under.
func albumHashTx(ctx context.Context, tx *sql.Tx, albumID int64, hash string, except int64) (int64, string, bool, error) {
	var id int64
	var stored string
	err := tx.QueryRowContext(ctx, `
		SELECT a.id, a.original_name FROM album_assets aa
		JOIN assets a ON a.id = aa.asset_id
		WHERE aa.album_id = ? AND a.id <> ? AND a.hash = ?
		ORDER BY a.id ASC LIMIT 1`, albumID, except, hash).Scan(&id, &stored)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, "", false, nil
	}
	if err != nil {
		return 0, "", false, err
	}
	return id, stored, true, nil
}

// albumNameClashTx finds the album member whose *display* name equals `name`
// (the membership's own name when it has one, else the asset's), ignoring case —
// a phone gallery treats IMG.JPG and img.jpg as one name — and ignoring `except`.
// It returns 0 when the name is free.
func albumNameClashTx(ctx context.Context, tx *sql.Tx, albumID int64, name string, except int64) (int64, string, string, error) {
	var id int64
	var hash, stored string
	err := tx.QueryRowContext(ctx, `
		SELECT a.id, a.hash, COALESCE(aa.name, a.original_name) FROM album_assets aa
		JOIN assets a ON a.id = aa.asset_id
		WHERE aa.album_id = ? AND a.id <> ? AND lower(COALESCE(aa.name, a.original_name)) = lower(?)
		ORDER BY a.id ASC LIMIT 1`, albumID, except, name).Scan(&id, &hash, &stored)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, "", "", nil
	}
	if err != nil {
		return 0, "", "", err
	}
	return id, hash, stored, nil
}

// maxNameAttempts bounds the "x (n).ext" search; reaching it means the album
// already holds that many same-named files, which is a data problem, not a
// naming one.
const maxNameAttempts = 10000

// freeNameInAlbumTx numbers a name the way a file manager does: "x.jpg" becomes
// "x (1).jpg", then "x (2).jpg" and so on, against the names this album's
// members currently display — a same-named file in another album is a different
// file to the user.
func freeNameInAlbumTx(ctx context.Context, tx *sql.Tx, albumID int64, name string) (string, error) {
	base, ext := splitExt(name)
	for n := 1; n <= maxNameAttempts; n++ {
		candidate := fmt.Sprintf("%s (%d)%s", base, n, ext)
		var taken int
		if err := tx.QueryRowContext(ctx, `
			SELECT COUNT(*) FROM album_assets aa
			JOIN assets a ON a.id = aa.asset_id
			WHERE aa.album_id = ? AND lower(COALESCE(aa.name, a.original_name)) = lower(?)`, albumID, candidate).Scan(&taken); err != nil {
			return "", err
		}
		if taken == 0 {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("album %d already holds %d files named %q", albumID, maxNameAttempts, name)
}

// splitExt splits "x.jpg" into "x" and ".jpg"; a name without an extension (or
// ending on the dot) comes back whole, matching ExtensionOf.
func splitExt(name string) (string, string) {
	i := strings.LastIndexByte(name, '.')
	if i < 0 || i+1 == len(name) {
		return name, ""
	}
	return name[:i], name[i:]
}

// favoriteAlbumName is the auto-managed favourites bucket. A photo "in" it is
// not filed there, it is starred, so deleting from that view deletes the photo
// rather than quietly un-starring it.
const favoriteAlbumName = "收藏"

// The two trunk roots. They are the library itself, not containers: nothing is
// ever merged *into* one (see MoveAlbum), and an asset left with nowhere to go
// is parked in the 共享相册 trunk's 散照.
const (
	trunkAlbumName   = "共享相册"
	trunkPrivateName = "隐私"
)

// AlbumScopedDelete reports whether deleting a photo inside `albumID` should
// remove only that album's reference (true) instead of the photo itself. Real
// albums are containers the user files into; 收藏 and the trunk roots (全部 /
// 视频) are views of the whole library, where deleting means deleting. The
// album must be one the caller can see, else ErrNotFound.
func (s *Store) AlbumScopedDelete(ctx context.Context, albumID, identityID int64) (bool, error) {
	al, err := s.VisibleAlbum(ctx, albumID, identityID)
	if err != nil {
		return false, err
	}
	return al.ParentID != nil && al.Name != favoriteAlbumName, nil
}

// RemoveOrTrash removes the asset from `albumID` and trashes the asset itself
// only when that was the last album holding it. The same bytes may sit in
// several albums — one asset row, one membership each — so deleting the copy in
// one album must not take the photo away from the others: the asset, and the
// blob behind it, stay untouched. Reports whether the asset ended up in the
// recycle bin, which is the caller's cue that local artifacts are now useless.
func (s *Store) RemoveOrTrash(ctx context.Context, albumID, assetID, identityID int64) (bool, error) {
	if _, err := s.VisibleAlbum(ctx, albumID, identityID); err != nil {
		return false, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()

	// The name the photo showed under inside this album (it may have been
	// numbered), read before the row goes: a trash entry has to remember it.
	var displayName, albumName string
	var parentID *int64
	err = tx.QueryRowContext(ctx, `
		SELECT COALESCE(aa.name, a.original_name), al.name, al.parent_id
		FROM album_assets aa
		JOIN assets a ON a.id = aa.asset_id
		JOIN albums al ON al.id = aa.album_id
		WHERE aa.album_id = ? AND aa.asset_id = ? AND a.deleted_at IS NULL`, albumID, assetID).
		Scan(&displayName, &albumName, &parentID)
	if errors.Is(err, sql.ErrNoRows) {
		return false, ErrNotFound
	}
	if err != nil {
		return false, err
	}

	now := time.Now().Unix()
	if _, err := tx.ExecContext(ctx,
		`DELETE FROM album_assets WHERE album_id = ? AND asset_id = ?`, albumID, assetID); err != nil {
		return false, err
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO sync_log (entity, entity_id, op, at) VALUES ('album_asset', ?, 'delete', ?)`,
		assetID, now); err != nil {
		return false, err
	}

	var left int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM album_assets WHERE asset_id = ?`, assetID).Scan(&left); err != nil {
		return false, err
	}
	if left > 0 {
		// 还有别的相册引用它：资产原样留着，回收站也不必进。
		return false, tx.Commit()
	}

	// 最后一处引用没了：整个资产进回收站，provenance 就记刚离开的这个相册。
	trunkID := albumID
	if parentID != nil {
		trunkID = *parentID
	}
	origin := trashOrigin{trunkID: &trunkID, albumID: &albumID, albumName: albumName, assetName: displayName}
	if err := s.trashAssetTx(ctx, tx, assetID, origin, now); err != nil {
		return false, err
	}
	return true, tx.Commit()
}

// RemoveOrPark removes the asset from `albumID`. When that was the last album
// holding it, the photo is parked in its trunk's 散照 bucket instead of being
// left belonging to nothing: an asset in no album appears in no listing (the
// trunks aggregate their members) and is not in the recycle bin either — a photo
// nobody can see and nobody can restore. Un-starring a favourite must not be a
// hidden delete, so an un-filed photo simply becomes an un-filed photo.
// Reports whether the photo had to be parked.
func (s *Store) RemoveOrPark(ctx context.Context, albumID, assetID, identityID int64) (bool, error) {
	if _, err := s.VisibleAlbum(ctx, albumID, identityID); err != nil {
		return false, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()

	var parentID *int64
	err = tx.QueryRowContext(ctx, `
		SELECT al.parent_id FROM album_assets aa
		JOIN albums al ON al.id = aa.album_id
		JOIN assets a ON a.id = aa.asset_id
		WHERE aa.album_id = ? AND aa.asset_id = ? AND a.deleted_at IS NULL`, albumID, assetID).Scan(&parentID)
	if errors.Is(err, sql.ErrNoRows) {
		return false, ErrNotFound
	}
	if err != nil {
		return false, err
	}

	now := time.Now().Unix()
	if _, err := tx.ExecContext(ctx,
		`DELETE FROM album_assets WHERE album_id = ? AND asset_id = ?`, albumID, assetID); err != nil {
		return false, err
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO sync_log (entity, entity_id, op, at) VALUES ('album_asset', ?, 'delete', ?)`,
		assetID, now); err != nil {
		return false, err
	}

	var left int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM album_assets WHERE asset_id = ?`, assetID).Scan(&left); err != nil {
		return false, err
	}
	if left > 0 {
		return false, tx.Commit()
	}

	trunkID := albumID
	if parentID != nil {
		trunkID = *parentID
	}
	bucket, err := s.scatterBucketTx(ctx, tx, trunkID)
	if err != nil {
		return false, err
	}
	if bucket == 0 {
		// 主干被清过或数据来自更早的版本：把桶补出来，别把照片丢在没有归属的地方。
		if bucket, err = s.childAlbumTx(ctx, tx, trunkID, "散照", now); err != nil {
			return false, err
		}
	}
	var name string
	if err := tx.QueryRowContext(ctx, `SELECT original_name FROM assets WHERE id = ?`, assetID).Scan(&name); err != nil {
		return false, err
	}
	membershipName, err := membershipNameTx(ctx, tx, bucket, name, assetID)
	if err != nil {
		return false, err
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT OR IGNORE INTO album_assets (album_id, asset_id, added_at, name) VALUES (?, ?, ?, ?)`,
		bucket, assetID, now, membershipName); err != nil {
		return false, err
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO sync_log (entity, entity_id, op, at) VALUES ('album_asset', ?, 'create', ?)`,
		assetID, now); err != nil {
		return false, err
	}
	return true, tx.Commit()
}

// ParkAsset files an asset that belongs to no album into its trunk's 散照
// bucket, creating the bucket when missing — the same landing spot the trash
// provenance falls back to. An asset held by nobody appears in no listing (the
// trunks aggregate their members) and is in no recycle bin either: a photo
// nobody can see and nobody can restore. Every path that creates an asset is
// supposed to end with it filed somewhere; this is the repair for the ones that
// could not reach their intended album. Assets that already have a home are
// left untouched, so it is safe to call unconditionally.
//
// ownerAlbumID is the album the upload was meant for: the photo lands in *that*
// album's trunk 散照, so a private upload that missed its album does not fall
// into the shared trunk where the whole family would see it. 0 parks in the
// shared trunk.
func (s *Store) ParkAsset(ctx context.Context, assetID, ownerAlbumID int64) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var name string
	var held int
	err = tx.QueryRowContext(ctx, `
		SELECT a.original_name,
		       (SELECT COUNT(*) FROM album_assets aa WHERE aa.asset_id = a.id)
		FROM assets a WHERE a.id = ? AND a.deleted_at IS NULL`, assetID).Scan(&name, &held)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if held > 0 {
		return nil
	}

	trunkID := int64(0)
	if ownerAlbumID > 0 {
		if trunkID, err = trunkIDOfAlbumTx(ctx, tx, ownerAlbumID); err != nil {
			trunkID = 0
		}
	}
	if trunkID == 0 {
		trunkID, err = trunkIDByName(ctx, tx, trunkAlbumName)
		if err != nil {
			return err
		}
	}
	if trunkID == 0 {
		return ErrNotFound
	}
	now := time.Now().Unix()
	bucket, err := s.scatterBucketTx(ctx, tx, trunkID)
	if err != nil {
		return err
	}
	if bucket == 0 {
		if bucket, err = s.childAlbumTx(ctx, tx, trunkID, "散照", now); err != nil {
			return err
		}
	}
	membershipName, err := membershipNameTx(ctx, tx, bucket, name, assetID)
	if err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT OR IGNORE INTO album_assets (album_id, asset_id, added_at, name) VALUES (?, ?, ?, ?)`,
		bucket, assetID, now, membershipName); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO sync_log (entity, entity_id, op, at) VALUES ('album_asset', ?, 'create', ?)`,
		assetID, now); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *Store) RemoveAssetFromAlbum(ctx context.Context, albumID, assetID int64) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx,
		`DELETE FROM album_assets WHERE album_id = ? AND asset_id = ?`, albumID, assetID)
	if err != nil {
		return err
	}
	if n, err := res.RowsAffected(); err == nil && n > 0 {
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO sync_log (entity, entity_id, op, at) VALUES ('album_asset', ?, 'delete', ?)`,
			assetID, time.Now().Unix()); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// AppendSyncLog records a sync change outside of the methods that already log
// internally; provided for completeness of the store contract.
func (s *Store) AppendSyncLog(ctx context.Context, entity string, id int64, op string) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO sync_log (entity, entity_id, op, at) VALUES (?, ?, ?, ?)`,
		entity, id, op, time.Now().Unix())
	return err
}

// GetChanges returns the sync_log rows with seq > cursor that this identity can
// act on: changes to assets and memberships it can see, and to albums it can
// see. Someone else's 隐私相册 never shows up in its feed.
func (s *Store) GetChanges(ctx context.Context, cursor int64, identityID int64) ([]Change, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT seq, entity, entity_id, op, at FROM sync_log
		WHERE seq > ? AND (
		  (entity IN ('asset','album_asset') AND `+assetVisibleCond("sync_log.entity_id")+`)
		  OR (entity = 'album' AND EXISTS (
		        SELECT 1 FROM albums av WHERE av.id = sync_log.entity_id
		          AND (av.owner_id IS NULL OR av.owner_id = ?)))
		)
		ORDER BY seq ASC`, cursor, identityID, identityID, identityID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	changes := make([]Change, 0)
	for rows.Next() {
		var c Change
		if err := rows.Scan(&c.Seq, &c.Entity, &c.EntityID, &c.Op, &c.At); err != nil {
			return nil, err
		}
		changes = append(changes, c)
	}
	return changes, rows.Err()
}

func encodeCursor(id int64) string {
	return base64.RawURLEncoding.EncodeToString([]byte(strconv.FormatInt(id, 10)))
}

func decodeCursor(s string) (int64, error) {
	if s == "" {
		return 0, nil
	}
	b, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil {
		return 0, err
	}
	return strconv.ParseInt(string(b), 10, 64)
}
