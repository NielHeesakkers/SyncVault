package rest

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
	"github.com/NielHeesakkers/SyncVault/internal/metadata"
	"github.com/go-chi/chi/v5"
)

// fileResponse is the JSON representation of a file metadata entry.
type fileResponse struct {
	ID          string    `json:"id"`
	Name        string    `json:"name"`
	IsDir       bool      `json:"is_dir"`
	Size        int64     `json:"size"`
	ContentHash string    `json:"content_hash,omitempty"`
	MimeType    string    `json:"mime_type,omitempty"`
	CreatedAt   time.Time `json:"created_at"`
	UpdatedAt   time.Time `json:"updated_at"`
}

// toFileResponse converts a metadata.File to a fileResponse.
func toFileResponse(f metadata.File) fileResponse {
	fr := fileResponse{
		ID:        f.ID,
		Name:      f.Name,
		IsDir:     f.IsDir,
		Size:      f.Size,
		CreatedAt: f.CreatedAt,
		UpdatedAt: f.UpdatedAt,
	}
	if f.ContentHash.Valid {
		fr.ContentHash = f.ContentHash.String
	}
	if f.MimeType.Valid {
		fr.MimeType = f.MimeType.String
	}
	return fr
}

// handleListFiles lists files for the current user (filtered by parent_id query param).
// Admins see all files; regular users see only their own.
func (s *Server) handleListFiles(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	parentID := r.URL.Query().Get("parent_id")

	files, err := s.db.ListChildren(parentID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not list files"})
		return
	}

	// Non-admins only see their own files.
	var result []fileResponse
	for _, f := range files {
		if claims.Role != "admin" && f.OwnerID != claims.UserID {
			continue
		}
		result = append(result, toFileResponse(f))
	}

	if result == nil {
		result = []fileResponse{}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"files": result})
}

// createFileRequest is the body for POST /api/files.
type createFileRequest struct {
	Name     string `json:"name"`
	ParentID string `json:"parent_id"`
	IsDir    bool   `json:"is_dir"`
}

// handleCreateFile creates a new folder or empty file entry.
func (s *Server) handleCreateFile(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())

	var req createFileRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	f, err := s.db.CreateFile(req.ParentID, claims.UserID, req.Name, req.IsDir, 0, "", "")
	if err != nil {
		if errors.Is(err, metadata.ErrDuplicateFile) {
			writeJSON(w, http.StatusConflict, map[string]string{"error": "file already exists"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not create file"})
		return
	}

	writeJSON(w, http.StatusCreated, toFileResponse(*f))
}

// handleUploadFile handles multipart file upload, stores content, and creates metadata + version.
func (s *Server) handleUploadFile(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())

	// Parse multipart form (limit to 32 MB in memory).
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "could not parse multipart form"})
		return
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing file field"})
		return
	}
	defer file.Close()

	parentID := r.FormValue("parent_id")

	// Read first 512 bytes for MIME detection.
	buf := make([]byte, 512)
	n, _ := file.Read(buf)
	mimeType := http.DetectContentType(buf[:n])

	// Seek back to beginning to store the full file.
	type readSeeker interface {
		io.Reader
		io.Seeker
	}
	if rs, ok := file.(readSeeker); ok {
		rs.Seek(0, io.SeekStart)
	} else {
		// Fallback: re-join the already-read bytes with the rest.
		// This path is taken when the multipart file doesn't implement Seeker.
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not seek file"})
		return
	}

	// Store in content-addressable storage.
	contentHash, size, err := s.store.Put(file)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not store file"})
		return
	}

	// Create file metadata entry.
	f, err := s.db.CreateFile(parentID, claims.UserID, header.Filename, false, size, contentHash, mimeType)
	if err != nil {
		if errors.Is(err, metadata.ErrDuplicateFile) {
			writeJSON(w, http.StatusConflict, map[string]string{"error": "file already exists"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not create file metadata"})
		return
	}

	// Create version 1.
	if _, err := s.db.CreateVersion(f.ID, 1, contentHash, "", size, claims.UserID); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not create version"})
		return
	}

	writeJSON(w, http.StatusCreated, toFileResponse(*f))
}

// updateFileRequest is the body for PUT /api/files/{id}.
type updateFileRequest struct {
	Name     string `json:"name"`
	ParentID string `json:"parent_id"`
}

// handleUpdateFile handles PUT /api/files/{id} — rename or move.
func (s *Server) handleUpdateFile(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	f, err := s.db.GetFileByID(id)
	if err != nil {
		if errors.Is(err, metadata.ErrFileNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "file not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get file"})
		return
	}

	var req updateFileRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	name := f.Name
	if req.Name != "" {
		name = req.Name
	}
	parentID := ""
	if f.ParentID.Valid {
		parentID = f.ParentID.String
	}
	if req.ParentID != "" {
		parentID = req.ParentID
	}

	if err := s.db.MoveFile(id, parentID, name); err != nil {
		if errors.Is(err, metadata.ErrFileNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "file not found"})
			return
		}
		if errors.Is(err, metadata.ErrDuplicateFile) {
			writeJSON(w, http.StatusConflict, map[string]string{"error": "file already exists at destination"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not update file"})
		return
	}

	updated, err := s.db.GetFileByID(id)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get updated file"})
		return
	}

	writeJSON(w, http.StatusOK, toFileResponse(*updated))
}

// handleDeleteFile handles DELETE /api/files/{id} — soft delete.
func (s *Server) handleDeleteFile(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	if err := s.db.SoftDeleteFile(id); err != nil {
		if errors.Is(err, metadata.ErrFileNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "file not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not delete file"})
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

// handleRestoreFile handles POST /api/files/{id}/restore — restore from trash.
func (s *Server) handleRestoreFile(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	if err := s.db.RestoreFile(id); err != nil {
		if errors.Is(err, metadata.ErrFileNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "file not found or not in trash"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not restore file"})
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "restored"})
}

// handleListTrash handles GET /api/trash — list trashed files for the current user.
func (s *Server) handleListTrash(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())

	files, err := s.db.ListTrashedFiles(claims.UserID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not list trashed files"})
		return
	}

	result := make([]fileResponse, 0, len(files))
	for _, f := range files {
		result = append(result, toFileResponse(f))
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"files": result})
}

// changeResponse is the JSON representation of a single change-feed entry.
// It extends fileResponse with parent_id and deleted_at so clients can handle deletions and moves.
type changeResponse struct {
	ID          string  `json:"id"`
	Name        string  `json:"name"`
	ParentID    *string `json:"parent_id"`
	IsDir       bool    `json:"is_dir"`
	Size        int64   `json:"size"`
	ContentHash string  `json:"content_hash,omitempty"`
	UpdatedAt   string  `json:"updated_at"`
	DeletedAt   *string `json:"deleted_at"`
}

// toChangeResponse converts a metadata.File to a changeResponse.
func toChangeResponse(f metadata.File) changeResponse {
	cr := changeResponse{
		ID:        f.ID,
		Name:      f.Name,
		IsDir:     f.IsDir,
		Size:      f.Size,
		UpdatedAt: f.UpdatedAt.UTC().Format(time.RFC3339),
	}
	if f.ParentID.Valid {
		s := f.ParentID.String
		cr.ParentID = &s
	}
	if f.ContentHash.Valid {
		cr.ContentHash = f.ContentHash.String
	}
	if f.DeletedAt.Valid {
		s := f.DeletedAt.String
		cr.DeletedAt = &s
	}
	return cr
}

// handleListChanges handles GET /api/changes?since=<ISO8601>&folder_id=<optional>.
// Returns all files changed (updated or deleted) after the given timestamp for the authenticated user.
// The folder_id parameter, when provided, limits results to files whose parent_id matches.
func (s *Server) handleListChanges(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())

	sinceStr := r.URL.Query().Get("since")
	if sinceStr == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing required query param: since"})
		return
	}

	// Try RFC3339Nano first (subsecond precision), then RFC3339
	since, err := time.Parse(time.RFC3339Nano, sinceStr)
	if err != nil {
		since, err = time.Parse(time.RFC3339, sinceStr)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid since timestamp: must be ISO 8601 (e.g. 2026-03-21T15:00:00Z)"})
			return
		}
	}

	folderID := r.URL.Query().Get("folder_id")

	changed, err := s.db.ListChangedFiles(since, claims.UserID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not list changes"})
		return
	}

	result := make([]changeResponse, 0, len(changed))
	for _, f := range changed {
		// Apply optional folder_id filter.
		if folderID != "" {
			parentID := ""
			if f.ParentID.Valid {
				parentID = f.ParentID.String
			}
			if parentID != folderID {
				continue
			}
		}
		result = append(result, toChangeResponse(f))
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"changes":     result,
		"server_time": time.Now().UTC().Format(time.RFC3339Nano),
	})
}

// handleDownloadFile streams a file's content from storage.
func (s *Server) handleDownloadFile(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	f, err := s.db.GetFileByID(id)
	if err != nil {
		if errors.Is(err, metadata.ErrFileNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "file not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get file"})
		return
	}

	if !f.ContentHash.Valid || f.ContentHash.String == "" {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]string{"error": "file has no content"})
		return
	}

	mimeType := "application/octet-stream"
	if f.MimeType.Valid && f.MimeType.String != "" {
		mimeType = f.MimeType.String
	}

	w.Header().Set("Content-Type", mimeType)
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, f.Name))

	if err := s.store.Get(f.ContentHash.String, w); err != nil {
		// Headers already sent; we can't write a JSON error at this point.
		return
	}
}
