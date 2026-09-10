package api

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/deminzhang/hongni/server/internal/blob"
	"github.com/deminzhang/hongni/server/internal/config"
	"github.com/deminzhang/hongni/server/internal/store"
)

// server wires the store, blob store, and config into HTTP handlers.
type server struct {
	store *store.Store
	blob  *blob.Store
	cfg   config.Config
}

// New assembles the full HTTP handler: /health unauthenticated, and an
// authenticated /api/v1/ subtree requiring a Bearer token.
func New(s *store.Store, b *blob.Store, cfg config.Config) http.Handler {
	sv := &server{store: s, blob: b, cfg: cfg}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", sv.handleHealth)

	api := http.NewServeMux()
	api.HandleFunc("GET /assets", sv.handleListAssets)
	api.HandleFunc("POST /assets", sv.handleCreateAsset)
	// The by-hash / {id}/original / {id}/thumb sub-paths overlap under stdlib
	// ServeMux wildcard rules, so they are dispatched manually in one handler
	// (exact plan URLs are preserved).
	api.HandleFunc("GET /assets/{path...}", sv.handleAssetGet)
	api.HandleFunc("DELETE /assets/{id}", sv.handleDeleteAsset)
	api.HandleFunc("PATCH /assets/{id}", sv.handleAssetPatch)
	api.HandleFunc("GET /albums", sv.handleListAlbums)
	api.HandleFunc("POST /albums", sv.handleCreateAlbum)
	api.HandleFunc("PATCH /albums/{id}", sv.handleUpdateAlbum)
	api.HandleFunc("DELETE /albums/{id}", sv.handleDeleteAlbum)
	api.HandleFunc("POST /albums/{id}/assets", sv.handleAddAssetToAlbum)
	api.HandleFunc("POST /albums/{id}/move", sv.handleMoveAlbum)
	api.HandleFunc("DELETE /albums/{id}/assets/{asset_id}", sv.handleRemoveAssetFromAlbum)
	api.HandleFunc("GET /trash", sv.handleListTrash)
	api.HandleFunc("POST /trash/{id}/restore", sv.handleRestoreAsset)
	api.HandleFunc("DELETE /trash/{id}", sv.handleDeleteTrashAsset)
	api.HandleFunc("DELETE /trash", sv.handleClearTrash)
	api.HandleFunc("GET /sync/changes", sv.handleSyncChanges)

	mux.Handle("/api/v1/", http.StripPrefix("/api/v1", sv.auth(api)))
	return mux
}

func (s *server) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := r.Header.Get("Authorization")
		const prefix = "Bearer "
		if !strings.HasPrefix(h, prefix) {
			writeErr(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		tok := strings.TrimPrefix(h, prefix)
		if subtle.ConstantTimeCompare([]byte(tok), []byte(s.cfg.Token)) != 1 {
			writeErr(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

// assetResponse extends an Asset with the upload-only fields deduplicated/thumb.
type assetResponse struct {
	store.Asset
	Deduplicated bool `json:"deduplicated"`
	Thumb        bool `json:"thumb"`
}

func (s *server) handleListAssets(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	filter := q.Get("filter")
	if filter == "" {
		filter = "all"
	}

	var albumID *int64
	if v := q.Get("album_id"); v != "" {
		id, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			writeErr(w, http.StatusBadRequest, "invalid album_id")
			return
		}
		albumID = &id
	}

	limit := 100
	if v := q.Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			writeErr(w, http.StatusBadRequest, "invalid limit")
			return
		}
		limit = n
	}

	assets, next, err := s.store.ListAssets(r.Context(), filter, albumID, q.Get("cursor"), limit)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"assets": assets, "next_cursor": next})
}

// handleAssetGet dispatches the overlapping GET sub-paths:
//
//	/assets/by-hash/{hash}    -> handleAssetByHash
//	/assets/{id}/original     -> handleOriginal
//	/assets/{id}/thumb        -> handleThumb
func (s *server) handleAssetGet(w http.ResponseWriter, r *http.Request) {
	rest := r.PathValue("path")
	parts := strings.Split(rest, "/")
	switch {
	case len(parts) == 1:
		// GET /assets/{id} — full Asset JSON (Stage 5 sync download).
		if id, err := parseID(parts[0]); err != nil {
			writeErr(w, http.StatusBadRequest, "invalid id")
		} else {
			s.handleAssetJSON(w, r, id)
		}
	case len(parts) == 2 && parts[0] == "by-hash":
		s.handleAssetByHash(w, r, parts[1])
	case len(parts) == 2 && parts[1] == "original":
		if id, err := parseID(parts[0]); err != nil {
			writeErr(w, http.StatusBadRequest, "invalid id")
		} else {
			s.handleOriginal(w, r, id)
		}
	case len(parts) == 2 && parts[1] == "thumb":
		if id, err := parseID(parts[0]); err != nil {
			writeErr(w, http.StatusBadRequest, "invalid id")
		} else {
			s.handleThumb(w, r, id)
		}
	default:
		writeErr(w, http.StatusNotFound, "not found")
	}
}

func (s *server) handleAssetJSON(w http.ResponseWriter, r *http.Request, id int64) {
	a, err := s.store.GetAsset(r.Context(), id)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, a)
}

func (s *server) handleAssetByHash(w http.ResponseWriter, r *http.Request, hash string) {
	a, found, err := s.store.GetAssetByHash(r.Context(), hash)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !found {
		writeErr(w, http.StatusNotFound, "not found")
		return
	}
	writeJSON(w, http.StatusOK, a)
}

func (s *server) handleCreateAsset(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseMultipartForm(64 << 20); err != nil {
		writeErr(w, http.StatusBadRequest, "bad multipart form: "+err.Error())
		return
	}

	file, _, err := r.FormFile("file")
	if err != nil {
		writeErr(w, http.StatusBadRequest, "missing file field")
		return
	}
	defer file.Close()

	mediaType := r.FormValue("media_type")
	if mediaType != "image" && mediaType != "video" {
		writeErr(w, http.StatusBadRequest, "media_type must be 'image' or 'video'")
		return
	}
	name := r.FormValue("name")
	if name == "" {
		name = "unnamed"
	}
	albumID := int64(0)
	if v := r.FormValue("album_id"); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			albumID = n
		}
	}
	mime := r.FormValue("mime_type")
	if mime == "" {
		mime = defaultMime(name, mediaType)
	}

	// Stream the upload to a temp file while hashing, so large videos are not
	// held in memory.
	tmp, err := osCreateTemp(s.cfg.DataDir, "upload-*.part")
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer osRemove(tmp)

	h := sha256.New()
	size, err := io.Copy(io.MultiWriter(tmp, h), file)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "read upload: "+err.Error())
		return
	}
	if err := tmp.Close(); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	hashHex := hex.EncodeToString(h.Sum(nil))

	_, dedup, err := s.store.GetAssetByHash(r.Context(), hashHex)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}

	// A name already used inside this album changes the outcome: the same bytes
	// are one file (link the copy that is already there), different bytes mean
	// this upload is the newcomer and gets numbered.
	if albumID > 0 {
		resolved, existing, err := s.store.NameInAlbum(r.Context(), albumID, hashHex, name)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		if existing > 0 {
			if err := s.store.AddAssetToAlbum(r.Context(), albumID, existing); err != nil {
				writeErr(w, http.StatusInternalServerError, err.Error())
				return
			}
			prev, err := s.store.GetAsset(r.Context(), existing)
			if err != nil {
				writeErr(w, http.StatusInternalServerError, err.Error())
				return
			}
			writeJSON(w, http.StatusCreated, assetResponse{Asset: *prev, Deduplicated: true})
			return
		}
		name = resolved
	}

	// Write blob (no-op if already present) and thumbnail.
	if err := withReader(tmp, func(r io.Reader) error {
		return s.blob.Put(hashHex, r)
	}); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	thumbOK := false
	if err := withReader(tmp, func(r io.Reader) error {
		var err error
		thumbOK, err = s.blob.EnsureThumb(hashHex, r)
		return err
	}); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}

	a := store.Asset{
		Hash:         hashHex,
		OriginalName: name,
		Ext:          store.ExtensionOf(name),
		MediaType:    mediaType,
		MimeType:     mime,
		Size:         size,
		CreatedAt:    time.Now().Unix(),
	}

	if mediaType == "image" {
		if err := withReader(tmp, func(r io.Reader) error {
			w0, h0, ok := blob.Dimensions(r)
			if ok {
				wi, hi := int64(w0), int64(h0)
				a.Width, a.Height = &wi, &hi
			}
			return nil
		}); err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
	}

	if v := r.FormValue("taken_at"); v != "" {
		if t, err := strconv.ParseInt(v, 10, 64); err == nil {
			a.TakenAt = &t
		}
	}

	id, err := s.store.CreateAsset(r.Context(), a)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	a.ID = id

	if albumID > 0 {
		_ = s.store.AddAssetToAlbum(r.Context(), albumID, id)
	}

	writeJSON(w, http.StatusCreated, assetResponse{Asset: a, Deduplicated: dedup, Thumb: thumbOK})
}

func (s *server) handleOriginal(w http.ResponseWriter, r *http.Request, id int64) {
	a, err := s.store.GetAsset(r.Context(), id)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	rc, err := s.blob.Open(a.Hash)
	if err != nil {
		writeErr(w, http.StatusNotFound, "blob missing")
		return
	}
	defer rc.Close()
	w.Header().Set("Content-Type", a.MimeType)
	w.Header().Set("Content-Length", strconv.FormatInt(a.Size, 10))
	_, _ = io.Copy(w, rc)
}

func (s *server) handleThumb(w http.ResponseWriter, r *http.Request, id int64) {
	a, err := s.store.GetAsset(r.Context(), id)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	rc, err := s.blob.OpenThumb(a.Hash)
	if err != nil {
		writeErr(w, http.StatusNotFound, "no thumbnail")
		return
	}
	defer rc.Close()
	w.Header().Set("Content-Type", "image/jpeg")
	_, _ = io.Copy(w, rc)
}

func (s *server) handleDeleteAsset(w http.ResponseWriter, r *http.Request) {
	id, err := parseID(r.PathValue("id"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	// `album_id` says which album the delete came from. Inside a real album that
	// means "drop this album's copy": the photo itself only reaches the recycle
	// bin when no other album holds it. 全部 / 视频 / 收藏 are views of the whole
	// library, so deleting there still means deleting the photo.
	if v := r.URL.Query().Get("album_id"); v != "" {
		if albumID, err := strconv.ParseInt(v, 10, 64); err == nil && albumID > 0 {
			scoped, err := s.store.AlbumScopedDelete(r.Context(), albumID)
			if err != nil {
				writeErr(w, http.StatusInternalServerError, err.Error())
				return
			}
			if scoped {
				trashed, err := s.store.RemoveOrTrash(r.Context(), albumID, id)
				if errors.Is(err, store.ErrNotFound) {
					writeErr(w, http.StatusNotFound, "not found")
					return
				}
				if err != nil {
					writeErr(w, http.StatusInternalServerError, err.Error())
					return
				}
				writeJSON(w, http.StatusOK, map[string]any{"ok": true, "trashed": trashed})
				return
			}
		}
	}
	// Active delete = soft delete into the recycle bin (30-day restore window).
	if err := s.store.TrashAsset(r.Context(), id); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeErr(w, http.StatusNotFound, "not found")
			return
		}
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "trashed": true})
}

func (s *server) handleAssetPatch(w http.ResponseWriter, r *http.Request) {
	id, err := parseID(r.PathValue("id"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	var req struct {
		OriginalName *string `json:"original_name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.OriginalName == nil || strings.TrimSpace(*req.OriginalName) == "" {
		writeErr(w, http.StatusBadRequest, "original_name is required")
		return
	}
	a, err := s.store.UpdateAssetName(r.Context(), id, strings.TrimSpace(*req.OriginalName))
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, a)
}

const trashRetentionSecs = 30 * 24 * 3600

// handleListTrash lists the recycle bin, optionally for one trunk, lazily
// purging assets older than the 30-day retention window first.
func (s *server) handleListTrash(w http.ResponseWriter, r *http.Request) {
	cutoff := time.Now().Unix() - trashRetentionSecs
	if hashes, err := s.store.PurgeExpiredTrash(r.Context(), cutoff); err == nil {
		for _, h := range hashes {
			_ = s.blob.Delete(h)
		}
	}

	q := r.URL.Query()
	var trunkID *int64
	if v := q.Get("trunk_id"); v != "" {
		id, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			writeErr(w, http.StatusBadRequest, "invalid trunk_id")
			return
		}
		trunkID = &id
	}
	limit := 100
	if v := q.Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			writeErr(w, http.StatusBadRequest, "invalid limit")
			return
		}
		limit = n
	}
	assets, next, err := s.store.ListTrash(r.Context(), trunkID, q.Get("cursor"), limit)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"assets": assets, "next_cursor": next})
}

func (s *server) handleRestoreAsset(w http.ResponseWriter, r *http.Request) {
	id, err := parseID(r.PathValue("id"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	a, err := s.store.RestoreAsset(r.Context(), id)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, a)
}

// handleDeleteTrashAsset permanently deletes one recycle-bin asset (and its
// physical blob when the ref count reaches zero).
func (s *server) handleDeleteTrashAsset(w http.ResponseWriter, r *http.Request) {
	id, err := parseID(r.PathValue("id"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	hash, refsLeft, err := s.store.DeleteAsset(r.Context(), id)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if refsLeft <= 0 {
		if err := s.blob.Delete(hash); err != nil {
			log.Printf("failed to delete blob %s: %v", hash, err)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// handleClearTrash empties the recycle bin (optionally one trunk).
func (s *server) handleClearTrash(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	var trunkID *int64
	if v := q.Get("trunk_id"); v != "" {
		id, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			writeErr(w, http.StatusBadRequest, "invalid trunk_id")
			return
		}
		trunkID = &id
	}
	hashes, err := s.store.ClearTrash(r.Context(), trunkID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	for _, h := range hashes {
		if err := s.blob.Delete(h); err != nil {
			log.Printf("failed to delete blob %s: %v", h, err)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) handleListAlbums(w http.ResponseWriter, r *http.Request) {
	albums, err := s.store.ListAlbums(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"albums": albums})
}

type createAlbumReq struct {
	Name     string `json:"name"`
	ParentID *int64 `json:"parent_id"`
	IsHidden bool   `json:"is_hidden"`
	SyncMode string `json:"sync_mode"`
}

func (s *server) handleCreateAlbum(w http.ResponseWriter, r *http.Request) {
	var req createAlbumReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if strings.TrimSpace(req.Name) == "" {
		writeErr(w, http.StatusBadRequest, "name is required")
		return
	}
	mode := req.SyncMode
	if mode == "" {
		mode = "backup"
	}
	if !validSyncMode(mode) {
		writeErr(w, http.StatusBadRequest, "invalid sync_mode")
		return
	}
	id, err := s.store.CreateAlbum(r.Context(), strings.TrimSpace(req.Name), req.ParentID, req.IsHidden, mode)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	a, err := s.store.GetAlbum(r.Context(), id)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, a)
}

func (s *server) handleUpdateAlbum(w http.ResponseWriter, r *http.Request) {
	id, err := parseID(r.PathValue("id"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}

	var req map[string]json.RawMessage
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}

	p := store.AlbumPatch{}
	if v, ok := req["name"]; ok {
		var sval string
		if err := json.Unmarshal(v, &sval); err != nil {
			writeErr(w, http.StatusBadRequest, "invalid name")
			return
		}
		p.Name = &sval
	}
	if v, ok := req["parent_id"]; ok {
		var n int64
		if strings.TrimSpace(string(v)) == "null" {
			n = 0 // clear parent: moves album to root
		} else if err := json.Unmarshal(v, &n); err != nil {
			writeErr(w, http.StatusBadRequest, "invalid parent_id")
			return
		}
		p.ParentID = &n
	}
	if v, ok := req["is_hidden"]; ok {
		var n int64
		if err := json.Unmarshal(v, &n); err != nil {
			writeErr(w, http.StatusBadRequest, "invalid is_hidden")
			return
		}
		p.IsHidden = &n
	}
	if v, ok := req["sync_mode"]; ok {
		var sval string
		if err := json.Unmarshal(v, &sval); err != nil {
			writeErr(w, http.StatusBadRequest, "invalid sync_mode")
			return
		}
		if !validSyncMode(sval) {
			writeErr(w, http.StatusBadRequest, "invalid sync_mode")
			return
		}
		p.SyncMode = &sval
	}
	if v, ok := req["sort_order"]; ok {
		var n int64
		if err := json.Unmarshal(v, &n); err != nil {
			writeErr(w, http.StatusBadRequest, "invalid sort_order")
			return
		}
		p.SortOrder = &n
	}

	a, err := s.store.UpdateAlbum(r.Context(), id, p)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, a)
}

func (s *server) handleDeleteAlbum(w http.ResponseWriter, r *http.Request) {
	id, err := parseID(r.PathValue("id"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	err = s.store.DeleteAlbum(r.Context(), id)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// handleMoveAlbum 迁移相册；目标层级已存在同名相册时并入它而不是建重复项。
func (s *server) handleMoveAlbum(w http.ResponseWriter, r *http.Request) {
	id, err := parseID(r.PathValue("id"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	var req struct {
		ParentID *int64 `json:"parent_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.ParentID != nil {
		if *req.ParentID < 0 {
			writeErr(w, http.StatusBadRequest, "invalid parent_id")
			return
		}
		if *req.ParentID == 0 {
			req.ParentID = nil // 0 与 null 同义，都表示移到主干层级
		}
	}
	album, mergedInto, moved, err := s.store.MoveAlbum(r.Context(), id, req.ParentID)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "album not found")
		return
	case errors.Is(err, store.ErrCycle):
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"album":       album,
		"merged_into": mergedInto,
		"moved":       moved,
	})
}

func (s *server) handleAddAssetToAlbum(w http.ResponseWriter, r *http.Request) {
	albumID, err := parseID(r.PathValue("id"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	var req struct {
		AssetID int64 `json:"asset_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.AssetID <= 0 {
		writeErr(w, http.StatusBadRequest, "asset_id is required")
		return
	}
	if err := s.store.AddAssetToAlbum(r.Context(), albumID, req.AssetID); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) handleRemoveAssetFromAlbum(w http.ResponseWriter, r *http.Request) {
	albumID, err := parseID(r.PathValue("id"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	assetID, err := parseID(r.PathValue("asset_id"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid asset_id")
		return
	}
	// Dropping a reference never leaves the photo without a home: taking it out
	// of its last album parks it in that trunk's 散照 (see RemoveOrPark), which
	// is what un-starring a favourite has to mean.
	parked, err := s.store.RemoveOrPark(r.Context(), albumID, assetID)
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not found")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "parked": parked})
}

func (s *server) handleSyncChanges(w http.ResponseWriter, r *http.Request) {
	cursor := int64(0)
	if v := r.URL.Query().Get("cursor"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			writeErr(w, http.StatusBadRequest, "invalid cursor")
			return
		}
		cursor = n
	}
	changes, err := s.store.GetChanges(r.Context(), cursor)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"changes": changes})
}

func parseID(s string) (int64, error) {
	id, err := strconv.ParseInt(s, 10, 64)
	if err != nil || id <= 0 {
		return 0, errors.New("invalid id")
	}
	return id, nil
}

func validSyncMode(m string) bool {
	switch m {
	case "backup", "local_only", "two_way", "mirror":
		return true
	}
	return false
}

func defaultMime(name, mediaType string) string {
	if mediaType == "video" {
		return "video/mp4"
	}
	switch strings.ToLower(extOf(name)) {
	case ".png":
		return "image/png"
	case ".gif":
		return "image/gif"
	case ".webp":
		return "image/webp"
	case ".heic":
		return "image/heic"
	case ".heif":
		return "image/heif"
	default:
		return "image/jpeg"
	}
}

func extOf(name string) string {
	if i := strings.LastIndexByte(name, '.'); i >= 0 {
		return name[i:]
	}
	return ""
}

// osCreateTemp creates a temp file inside dataDir, so it is on the same
// filesystem as the blobs directory (safe for atomic rename).
func osCreateTemp(dataDir, pattern string) (*os.File, error) {
	return os.CreateTemp(dataDir, pattern)
}

// osRemove removes a temp file path; the file is assumed already closed.
func osRemove(f *os.File) {
	_ = f.Close()
	_ = os.Remove(f.Name())
}

// withReader reopens the temp file read-only and passes a reader to fn,
// closing it afterwards. The file must have been written and closed first.
func withReader(f *os.File, fn func(io.Reader) error) error {
	rc, err := os.Open(f.Name())
	if err != nil {
		return err
	}
	defer rc.Close()
	return fn(rc)
}
