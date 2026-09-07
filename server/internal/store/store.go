package store

import (
	"context"
	"database/sql"
	"encoding/base64"
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

// Album mirrors a row in the albums table.
type Album struct {
	ID        int64  `json:"id"`
	Name      string `json:"name"`
	ParentID  *int64 `json:"parent_id"`
	IsHidden  int64  `json:"is_hidden"`
	SyncMode  string `json:"sync_mode"`
	SortOrder int64  `json:"sort_order"`
	CreatedAt int64  `json:"created_at"`
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
`

// Open opens (creating if necessary) the SQLite database at path, enables WAL
// and foreign keys, and applies the schema migration.
func Open(path string) (*Store, error) {
	dsn := path + "?_pragma=journal_mode(WAL)&_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)"
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
	cols := []struct{ name, ddl string }{
		{"deleted_at", "ALTER TABLE assets ADD COLUMN deleted_at INTEGER"},
		{"deleted_trunk_id", "ALTER TABLE assets ADD COLUMN deleted_trunk_id INTEGER"},
		{"deleted_album_id", "ALTER TABLE assets ADD COLUMN deleted_album_id INTEGER"},
		{"ext", "ALTER TABLE assets ADD COLUMN ext TEXT"},
	}
	extAdded := false
	for _, c := range cols {
		exists, err := s.columnExists("assets", c.name)
		if err != nil {
			return err
		}
		if exists {
			continue
		}
		if _, err := s.db.Exec(c.ddl); err != nil {
			return fmt.Errorf("migrate %s: %w", c.name, err)
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

// seedTrunks ensures the two fixed top-level trunks (相册 / 隐私) and their
// built-in scattered-photo buckets exist. Trunks are the only roots; every
// user album is a flat child of one of the trunks.
func (s *Store) seedTrunks() error {
	now := time.Now().Unix()

	// Legacy rename: 私密相册 → 隐私 (idempotent).
	if _, err := s.db.Exec(`
		UPDATE albums SET name = '隐私'
		WHERE name = '私密相册' AND parent_id IS NULL
		  AND NOT EXISTS (SELECT 1 FROM albums WHERE name = '隐私' AND parent_id IS NULL)`); err != nil {
		return err
	}

	trunks := []struct {
		name   string
		hidden int64
	}{
		{"相册", 0},
		{"隐私", 1},
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
		{"收藏", "相册", 0},
		{"收藏", "隐私", 1},
		{"散照", "相册", 0},
		{"散照", "隐私", 1},
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

func (s *Store) GetAssetByHash(ctx context.Context, hash string) (*Asset, bool, error) {
	a, err := scanAsset(s.db.QueryRowContext(ctx, assetCols+" FROM assets WHERE hash = ? ORDER BY id ASC LIMIT 1", hash))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	return a, true, nil
}

const assetCols = "SELECT id, hash, original_name, ext, media_type, mime_type, size, width, height, taken_at, created_at, deleted_at, deleted_trunk_id, deleted_album_id"

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
func (s *Store) ListAssets(ctx context.Context, filter string, albumID *int64, cursor string, limit int) ([]Asset, string, error) {
	if limit <= 0 || limit > 1000 {
		limit = 100
	}
	lastID, err := decodeCursor(cursor)
	if err != nil {
		return nil, "", fmt.Errorf("bad cursor: %w", err)
	}

	var conds []string
	var args []any
	switch filter {
	case "videos":
		conds = append(conds, "media_type = 'video'")
	default:
		conds = append(conds, "media_type IN ('image','video')")
	}
	// ListAssets is the active-asset listing; trashed assets live in the
	// recycle bin and are listed via ListTrash.
	conds = append(conds, "deleted_at IS NULL")
	if albumID != nil {
		al, err := s.GetAlbum(ctx, *albumID)
		if err != nil && !errors.Is(err, ErrNotFound) {
			return nil, "", err
		}
		if err == nil && al.ParentID == nil {
			// Trunk (相册/隐私 root): aggregate every descendant album's
			// members (built-in 散照/收藏 buckets plus user sub-albums), so a
			// single "全部" request returns 散照 + all sub-albums.
			conds = append(conds, "id IN (SELECT asset_id FROM album_assets WHERE album_id IN (SELECT id FROM albums WHERE parent_id = ?))")
		} else {
			conds = append(conds, "id IN (SELECT asset_id FROM album_assets WHERE album_id = ?)")
		}
		args = append(args, *albumID)
	}
	if lastID > 0 {
		conds = append(conds, "id < ?")
		args = append(args, lastID)
	}

	q := assetCols + " FROM assets"
	if len(conds) > 0 {
		q += " WHERE " + strings.Join(conds, " AND ")
	}
	q += " ORDER BY id DESC LIMIT " + strconv.Itoa(limit+1)

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

// UpdateAssetName renames an asset's display name (original_name) and logs the
// change to sync_log. It returns the updated asset.
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
func (s *Store) deleteAssetRow(ctx context.Context, tx *sql.Tx, id int64, at int64) (string, int, error) {
	var h string
	err := tx.QueryRowContext(ctx, `SELECT hash FROM assets WHERE id = ?`, id).Scan(&h)
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
// blob is kept so the photo can still be restored within 7 days.
func (s *Store) TrashAsset(ctx context.Context, id int64) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var h string
	err = tx.QueryRowContext(ctx, `SELECT hash FROM assets WHERE id = ? AND deleted_at IS NULL`, id).Scan(&h)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}

	trunkID, albumID, err := s.sourceAlbumTx(ctx, tx, id)
	if err != nil {
		return err
	}

	now := time.Now().Unix()
	if _, err := tx.ExecContext(ctx,
		`UPDATE assets SET deleted_at = ?, deleted_trunk_id = ?, deleted_album_id = ? WHERE id = ?`,
		now, trunkID, albumID, id); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM album_assets WHERE asset_id = ?`, id); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO sync_log (entity, entity_id, op, at) VALUES ('asset', ?, 'delete', ?)`,
		id, now); err != nil {
		return err
	}
	return tx.Commit()
}

// RestoreAsset returns a trashed asset to the active set, re-adding it to the
// album it was deleted from (or the trunk's 散照 bucket if that album is gone).
func (s *Store) RestoreAsset(ctx context.Context, id int64) (*Asset, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	var trunkID, albumID *int64
	err = tx.QueryRowContext(ctx,
		`SELECT deleted_trunk_id, deleted_album_id FROM assets WHERE id = ? AND deleted_at IS NOT NULL`,
		id).Scan(&trunkID, &albumID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}

	now := time.Now().Unix()
	if _, err := tx.ExecContext(ctx,
		`UPDATE assets SET deleted_at = NULL, deleted_trunk_id = NULL, deleted_album_id = NULL WHERE id = ?`,
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
		if _, err := tx.ExecContext(ctx,
			`INSERT OR IGNORE INTO album_assets (album_id, asset_id, added_at) VALUES (?, ?, ?)`,
			targetID, id, now); err != nil {
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
func (s *Store) ListTrash(ctx context.Context, trunkID *int64, cursor string, limit int) ([]Asset, string, error) {
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
		conds = append(conds, "deleted_trunk_id = ?")
		args = append(args, *trunkID)
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
func (s *Store) ClearTrash(ctx context.Context, trunkID *int64) ([]string, error) {
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

// sourceAlbumTx picks the album the asset is most meaningfully "in" for trash
// provenance: the smallest-id non-收藏 album (用户相册 or 散照 bucket), falling
// back to 收藏 if that's all it has, else the 相册 trunk.
func (s *Store) sourceAlbumTx(ctx context.Context, tx *sql.Tx, assetID int64) (*int64, *int64, error) {
	rows, err := tx.QueryContext(ctx, `
		SELECT a.id, a.parent_id FROM albums a
		JOIN album_assets aa ON aa.album_id = a.id
		WHERE aa.asset_id = ?
		ORDER BY (a.name = '收藏') ASC, a.id ASC`, assetID)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	var albumID int64
	var parentID *int64
	found := false
	for rows.Next() {
		var pid *int64
		if err := rows.Scan(&albumID, &pid); err != nil {
			return nil, nil, err
		}
		parentID = pid
		found = true
		break
	}
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}
	if !found {
		tid, err := s.trunkIDByNameTx(ctx, tx, "相册")
		if err != nil {
			return nil, nil, err
		}
		return &tid, nil, nil
	}
	var trunkID *int64
	if parentID == nil {
		trunkID = &albumID
	} else {
		trunkID = parentID
	}
	return trunkID, &albumID, nil
}

func (s *Store) trunkIDByNameTx(ctx context.Context, tx *sql.Tx, name string) (int64, error) {
	var id int64
	err := tx.QueryRowContext(ctx, `SELECT id FROM albums WHERE parent_id IS NULL AND name = ?`, name).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	return id, err
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

func (s *Store) CreateAlbum(ctx context.Context, name string, parentID *int64, isHidden bool, syncMode string) (int64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()

	now := time.Now().Unix()
	hidden := int64(0)
	if isHidden {
		hidden = 1
	}
	res, err := tx.ExecContext(ctx,
		`INSERT INTO albums (name, parent_id, is_hidden, sync_mode, sort_order, created_at)
		 VALUES (?, ?, ?, ?, 0, ?)`, name, parentID, hidden, syncMode, now)
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

func (s *Store) ListAlbums(ctx context.Context) ([]Album, error) {
	rows, err := s.db.QueryContext(ctx, albumCols+" FROM albums ORDER BY parent_id, sort_order, name")
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

const albumCols = "SELECT id, name, parent_id, is_hidden, sync_mode, sort_order, created_at"

func scanAlbum(row rowScanner) (*Album, error) {
	var al Album
	if err := row.Scan(&al.ID, &al.Name, &al.ParentID, &al.IsHidden, &al.SyncMode, &al.SortOrder, &al.CreatedAt); err != nil {
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

func (s *Store) DeleteAlbum(ctx context.Context, id int64) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

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
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO sync_log (entity, entity_id, op, at) VALUES ('album', ?, 'delete', ?)`,
		id, time.Now().Unix()); err != nil {
		return err
	}
	return tx.Commit()
}

// AddAssetToAlbum is idempotent.
func (s *Store) AddAssetToAlbum(ctx context.Context, albumID, assetID int64) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	res, err := tx.ExecContext(ctx,
		`INSERT OR IGNORE INTO album_assets (album_id, asset_id, added_at) VALUES (?, ?, ?)`,
		albumID, assetID, time.Now().Unix())
	if err != nil {
		return err
	}
	if n, err := res.RowsAffected(); err == nil && n > 0 {
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO sync_log (entity, entity_id, op, at) VALUES ('album_asset', ?, 'create', ?)`,
			assetID, time.Now().Unix()); err != nil {
			return err
		}
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

// GetChanges returns sync_log rows with seq > cursor, ordered ascending.
func (s *Store) GetChanges(ctx context.Context, cursor int64) ([]Change, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT seq, entity, entity_id, op, at FROM sync_log WHERE seq > ? ORDER BY seq ASC`, cursor)
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
