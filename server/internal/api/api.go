package api

import (
	"context"
	"crypto/rand"
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
	"sync"
	"time"
	"unicode/utf8"

	"github.com/deminzhang/hongni/server/internal/blob"
	"github.com/deminzhang/hongni/server/internal/config"
	"github.com/deminzhang/hongni/server/internal/store"
)

// session is who a request is acting as: the identity resolved from its
// X-Hongni-Session token.
type session struct {
	identityID int64
	name       string
}

// server wires the store, blob store, and config into HTTP handlers.
type server struct {
	store *store.Store
	blob  *blob.Store
	cfg   config.Config

	// mu guards sessions. Sessions live in memory only: a restart logs everyone
	// out, and the clients log straight back in with the 身份 ID + PIN they keep.
	mu       sync.RWMutex
	sessions map[string]session
}

// New assembles the full HTTP handler: /health unauthenticated, and an
// authenticated /api/v1/ subtree requiring a Bearer token. Inside that, the
// data routes additionally require a session (X-Hongni-Session), which is what
// decides whose 隐私相册 is in view; only /identity/login is reachable with the
// token alone.
func New(s *store.Store, b *blob.Store, cfg config.Config) http.Handler {
	sv := &server{store: s, blob: b, cfg: cfg, sessions: map[string]session{}}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", sv.handleHealth)

	api := http.NewServeMux()
	api.HandleFunc("POST /identity/login", sv.handleIdentityLogin)
	api.HandleFunc("POST /identity/pin", sv.withIdentity(sv.handleIdentityPin))
	api.HandleFunc("GET /assets", sv.withIdentity(sv.handleListAssets))
	api.HandleFunc("POST /assets", sv.withIdentity(sv.handleCreateAsset))
	// The by-hash / {id}/original / {id}/thumb sub-paths overlap under stdlib
	// ServeMux wildcard rules, so they are dispatched manually in one handler
	// (exact plan URLs are preserved).
	api.HandleFunc("GET /assets/{path...}", sv.withIdentity(sv.handleAssetGet))
	api.HandleFunc("DELETE /assets/{id}", sv.withIdentity(sv.handleDeleteAsset))
	api.HandleFunc("PATCH /assets/{id}", sv.withIdentity(sv.handleAssetPatch))
	api.HandleFunc("GET /albums", sv.withIdentity(sv.handleListAlbums))
	api.HandleFunc("POST /albums", sv.withIdentity(sv.handleCreateAlbum))
	api.HandleFunc("PATCH /albums/{id}", sv.withIdentity(sv.handleUpdateAlbum))
	api.HandleFunc("DELETE /albums/{id}", sv.withIdentity(sv.handleDeleteAlbum))
	api.HandleFunc("POST /albums/{id}/assets", sv.withIdentity(sv.handleAddAssetToAlbum))
	api.HandleFunc("POST /albums/{id}/move", sv.withIdentity(sv.handleMoveAlbum))
	api.HandleFunc("DELETE /albums/{id}/assets/{asset_id}", sv.withIdentity(sv.handleRemoveAssetFromAlbum))
	api.HandleFunc("GET /trash", sv.withIdentity(sv.handleListTrash))
	api.HandleFunc("POST /trash/{id}/restore", sv.withIdentity(sv.handleRestoreAsset))
	api.HandleFunc("DELETE /trash/{id}", sv.withIdentity(sv.handleDeleteTrashAsset))
	api.HandleFunc("DELETE /trash", sv.withIdentity(sv.handleClearTrash))
	api.HandleFunc("GET /sync/changes", sv.withIdentity(sv.handleSyncChanges))

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
	writeJSON(w, code, map[string]any{"error": msg})
}

// storeErr turns a store error into the response: ErrNotFound is a 404 — the
// caller can tell "gone" from "it exists but is not yours", and for a photo in
// someone else's 隐私相册 the two are the same answer on purpose.
func storeErr(w http.ResponseWriter, err error) {
	if errors.Is(err, store.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not found")
		return
	}
	writeErr(w, http.StatusInternalServerError, err.Error())
}

type ctxKey int

const identityKey ctxKey = 0

// sessionOf returns the identity behind the request. Handlers reachable without
// a session (the login route) get the zero value.
func sessionOf(r *http.Request) session {
	sess, _ := r.Context().Value(identityKey).(session)
	return sess
}

// withIdentity requires a live session and hands it to the handler through the
// request context.
func (s *server) withIdentity(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sess, ok := s.lookupSession(r.Header.Get("X-Hongni-Session"))
		if !ok {
			writeErr(w, http.StatusUnauthorized, "未登录")
			return
		}
		h(w, r.WithContext(context.WithValue(r.Context(), identityKey, sess)))
	}
}

// newSession mints a session token for an identity and remembers it.
func (s *server) newSession(id int64, name string) (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	token := hex.EncodeToString(buf)
	s.mu.Lock()
	s.sessions[token] = session{identityID: id, name: name}
	s.mu.Unlock()
	return token, nil
}

func (s *server) lookupSession(token string) (session, bool) {
	if token == "" {
		return session{}, false
	}
	s.mu.RLock()
	sess, ok := s.sessions[token]
	s.mu.RUnlock()
	return sess, ok
}

// dropSessions 作废该身份的全部会话：PIN 换过之后，旧会话不该继续有效。
func (s *server) dropSessions(identityID int64) {
	s.mu.Lock()
	for token, sess := range s.sessions {
		if sess.identityID == identityID {
			delete(s.sessions, token)
		}
	}
	s.mu.Unlock()
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

// handleIdentityLogin exchanges 身份 ID + PIN for a session. An unknown name
// registers with the PIN given here — 首次注册为准 — and is handed its 隐私
// trunk; a known name has to match the stored PIN.
func (s *server) handleIdentityLogin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Identity string `json:"identity"`
		PIN      string `json:"pin"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	name := strings.TrimSpace(req.Identity)
	if !validIdentityName(name) {
		writeErr(w, http.StatusBadRequest, "身份 ID 需为 1–32 个字符")
		return
	}
	if !validPIN(req.PIN) {
		writeErr(w, http.StatusBadRequest, "PIN 需为 4–6 位数字")
		return
	}

	ident, registered, err := s.store.AuthIdentity(r.Context(), name, req.PIN)
	if errors.Is(err, store.ErrIdentityPIN) {
		writeErr(w, http.StatusUnauthorized, "身份 ID 或 PIN 不正确")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}

	token, err := s.newSession(ident.ID, ident.Name)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	privateID, err := s.store.PrivateTrunkID(r.Context(), ident.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	sharedID, err := s.store.SharedTrunkID(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"session":          token,
		"identity":         ident,
		"private_trunk_id": privateID,
		"shared_trunk_id":  sharedID,
		"registered":       registered,
	})
}

// handleIdentityPin changes the caller's own PIN and rotates its sessions: the
// old ones are dropped (a changed PIN must not leave old logins alive) and the
// caller is handed a fresh one so it stays logged in.
func (s *server) handleIdentityPin(w http.ResponseWriter, r *http.Request) {
	sess := sessionOf(r)
	var req struct {
		PIN    string `json:"pin"`
		NewPIN string `json:"new_pin"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if !validPIN(req.NewPIN) {
		writeErr(w, http.StatusBadRequest, "PIN 需为 4–6 位数字")
		return
	}

	err := s.store.SetIdentityPIN(r.Context(), sess.identityID, req.PIN, req.NewPIN)
	if errors.Is(err, store.ErrIdentityPIN) {
		writeErr(w, http.StatusUnauthorized, "当前 PIN 不正确")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}

	s.dropSessions(sess.identityID)
	token, err := s.newSession(sess.identityID, sess.name)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "session": token})
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

	assets, next, err := s.store.ListAssets(r.Context(), filter, albumID, q.Get("cursor"), limit, sessionOf(r).identityID)
	if err != nil {
		storeErr(w, err)
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
	a, err := s.store.GetAssetVisible(r.Context(), id, sessionOf(r).identityID)
	if err != nil {
		storeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, a)
}

func (s *server) handleAssetByHash(w http.ResponseWriter, r *http.Request, hash string) {
	a, found, err := s.store.GetAssetByHash(r.Context(), hash, sessionOf(r).identityID)
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
	// Cap the request body as a whole, not just the in-memory part of the form:
	// ParseMultipartForm spills anything larger than its argument to disk, so
	// without this one request decides how much of the server's disk to take.
	// Large videos are still fine, unbounded uploads are not.
	r.Body = http.MaxBytesReader(w, r.Body, maxUploadBytes)
	if err := r.ParseMultipartForm(64 << 20); err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			writeErr(w, http.StatusRequestEntityTooLarge, "upload too large")
			return
		}
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
	identityID := sessionOf(r).identityID
	// 目标相册必须是这个身份看得见的：看不见就当不存在。少了这一步，一次带着别人
	// 隐私主干 id 的上传会在入册失败后由 散照 兜底塞进那个人的隐私相册里。
	if albumID > 0 {
		if _, err := s.store.VisibleAlbum(r.Context(), albumID, identityID); err != nil {
			storeErr(w, err)
			return
		}
	}
	// The client supplies the MIME type and it is echoed back as the
	// Content-Type of /original, so only media types are accepted: an upload can
	// never turn the server's own origin into a text/html (or script) host.
	mime := r.FormValue("mime_type")
	if !strings.HasPrefix(mime, "image/") && !strings.HasPrefix(mime, "video/") {
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

	_, dedup, err := s.store.GetAssetByHash(r.Context(), hashHex, identityID)
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
			if _, err := s.store.AddAssetToAlbum(r.Context(), albumID, existing, identityID, false); err != nil {
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
	if err := withReader(tmp, func(r *os.File) error {
		return s.blob.Put(hashHex, r)
	}); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	thumbOK := false
	if err := withReader(tmp, func(r *os.File) error {
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
		if err := withReader(tmp, func(r *os.File) error {
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
		// Filing must not be silently skippable: an asset held by no album shows
		// up in no listing and in no recycle bin. When the link fails, park it in
		// the trunk's 散照 so the photo is still visible and restorable.
		if _, err := s.store.AddAssetToAlbum(r.Context(), albumID, id, identityID, false); err != nil {
			log.Printf("asset %d: add to album %d failed: %v", id, albumID, err)
			if perr := s.store.ParkAsset(r.Context(), id, albumID); perr != nil {
				log.Printf("asset %d: parking after failed link also failed: %v", id, perr)
			}
		}
	}

	writeJSON(w, http.StatusCreated, assetResponse{Asset: a, Deduplicated: dedup, Thumb: thumbOK})
}

func (s *server) handleOriginal(w http.ResponseWriter, r *http.Request, id int64) {
	a, err := s.store.GetAssetVisible(r.Context(), id, sessionOf(r).identityID)
	if err != nil {
		storeErr(w, err)
		return
	}
	rc, err := s.blob.Open(a.Hash)
	if err != nil {
		writeErr(w, http.StatusNotFound, "blob missing")
		return
	}
	defer rc.Close()
	w.Header().Set("Content-Type", a.MimeType)
	// The bytes are user content: never let a browser sniff them into something
	// executable on this origin.
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Length", strconv.FormatInt(a.Size, 10))
	_, _ = io.Copy(w, rc)
}

func (s *server) handleThumb(w http.ResponseWriter, r *http.Request, id int64) {
	a, err := s.store.GetAssetVisible(r.Context(), id, sessionOf(r).identityID)
	if err != nil {
		storeErr(w, err)
		return
	}
	rc, err := s.blob.OpenThumb(a.Hash)
	if err != nil {
		writeErr(w, http.StatusNotFound, "no thumbnail")
		return
	}
	defer rc.Close()
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	_, _ = io.Copy(w, rc)
}

func (s *server) handleDeleteAsset(w http.ResponseWriter, r *http.Request) {
	id, err := parseID(r.PathValue("id"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "invalid id")
		return
	}
	identityID := sessionOf(r).identityID
	if _, err := s.store.GetAssetVisible(r.Context(), id, identityID); err != nil {
		storeErr(w, err)
		return
	}
	// `album_id` says which album the delete came from. Inside a real album that
	// means "drop this album's copy": the photo itself only reaches the recycle
	// bin when no other album holds it. 全部 / 视频 / 收藏 are views of the whole
	// library, so deleting there still means deleting the photo.
	if v := r.URL.Query().Get("album_id"); v != "" {
		if albumID, err := strconv.ParseInt(v, 10, 64); err == nil && albumID > 0 {
			scoped, err := s.store.AlbumScopedDelete(r.Context(), albumID, identityID)
			if err != nil {
				storeErr(w, err)
				return
			}
			if scoped {
				trashed, err := s.store.RemoveOrTrash(r.Context(), albumID, id, identityID)
				if err != nil {
					storeErr(w, err)
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
	if _, err := s.store.GetAssetVisible(r.Context(), id, sessionOf(r).identityID); err != nil {
		storeErr(w, err)
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

// Largest upload the server accepts in one request (4 GiB). Comfortably above
// any phone video, and the point where "the client is wrong" stops being a
// better explanation than "the disk is about to fill up".
const maxUploadBytes = 4 << 30

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
	assets, next, err := s.store.ListTrash(r.Context(), trunkID, q.Get("cursor"), limit, sessionOf(r).identityID)
	if err != nil {
		storeErr(w, err)
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
	if _, err := s.store.GetAssetVisible(r.Context(), id, sessionOf(r).identityID); err != nil {
		storeErr(w, err)
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
	if _, err := s.store.GetAssetVisible(r.Context(), id, sessionOf(r).identityID); err != nil {
		storeErr(w, err)
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
	hashes, err := s.store.ClearTrash(r.Context(), trunkID, sessionOf(r).identityID)
	if err != nil {
		storeErr(w, err)
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
	albums, err := s.store.ListAlbums(r.Context(), sessionOf(r).identityID)
	if err != nil {
		storeErr(w, err)
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
	id, err := s.store.CreateAlbum(r.Context(), strings.TrimSpace(req.Name), req.ParentID, req.IsHidden, mode, sessionOf(r).identityID)
	if err != nil {
		storeErr(w, err)
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
	if _, err := s.store.VisibleAlbum(r.Context(), id, sessionOf(r).identityID); err != nil {
		storeErr(w, err)
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
	al, err := s.store.VisibleAlbum(r.Context(), id, sessionOf(r).identityID)
	if err != nil {
		storeErr(w, err)
		return
	}
	// 主干是库本身：它没有父级，删掉之后这个身份连自己的 隐私 都再也找不到。
	if al.ParentID == nil {
		writeErr(w, http.StatusBadRequest, "不能删除顶层相册")
		return
	}
	if err := s.store.DeleteAlbum(r.Context(), id); err != nil {
		storeErr(w, err)
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
	album, mergedInto, moved, err := s.store.MoveAlbum(r.Context(), id, req.ParentID, sessionOf(r).identityID)
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
	// only_here is 转到隐私相册: the client says the photo is moving, not being
	// copied, so the server drops its references in the shared albums rather
	// than trusting the client to clean up after itself.
	var req struct {
		AssetID  int64 `json:"asset_id"`
		OnlyHere bool  `json:"only_here"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.AssetID <= 0 {
		writeErr(w, http.StatusBadRequest, "asset_id is required")
		return
	}
	detached, err := s.store.AddAssetToAlbum(r.Context(), albumID, req.AssetID, sessionOf(r).identityID, req.OnlyHere)
	if err != nil {
		storeErr(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "detached_shared": detached})
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
	parked, err := s.store.RemoveOrPark(r.Context(), albumID, assetID, sessionOf(r).identityID)
	if err != nil {
		storeErr(w, err)
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
	changes, err := s.store.GetChanges(r.Context(), cursor, sessionOf(r).identityID)
	if err != nil {
		storeErr(w, err)
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

// validPIN accepts 4–6 digits: long enough that guessing is not free, short
// enough that a family member actually types it at the 隐私相册 door.
func validPIN(s string) bool {
	if len(s) < 4 || len(s) > 6 {
		return false
	}
	for i := range len(s) {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// validIdentityName accepts 1–32 characters of a name already trimmed.
func validIdentityName(s string) bool {
	n := utf8.RuneCountInString(s)
	return n >= 1 && n <= 32
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

// withReader reopens the temp file read-only and passes it to fn, closing it
// afterwards. The file must have been written and closed first. The handle (not
// a narrowed io.Reader) is handed over so decoders that must look before they
// leap — EnsureThumb reads the header, then seeks back for the full decode —
// can do so on the same open file.
func withReader(f *os.File, fn func(*os.File) error) error {
	rc, err := os.Open(f.Name())
	if err != nil {
		return err
	}
	defer rc.Close()
	return fn(rc)
}
