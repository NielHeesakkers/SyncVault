package rest

import (
	"archive/zip"
	"errors"
	"fmt"
	"io"
	"net/http"
	"path"
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

	// Non-admins only see their own files at root level.
	// When navigating inside a specific folder (parentID set), show all children
	// regardless of owner so team folder contents are visible.
	var result []fileResponse
	for _, f := range files {
		if claims.Role != "admin" && parentID == "" && f.OwnerID != claims.UserID {
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

// fileAtTimeResponse is the JSON representation of one file in the history view.
type fileAtTimeResponse struct {
	ID          string    `json:"id"`
	Name        string    `json:"name"`
	IsDir       bool      `json:"is_dir"`
	Size        int64     `json:"size"`
	VersionNum  int       `json:"version_num"`
	VersionID   string    `json:"version_id"`
	ContentHash string    `json:"content_hash,omitempty"`
	UpdatedAt   time.Time `json:"updated_at"`
}

// handleFilesAtTime handles GET /api/files/history?parent_id=X&at=<ISO8601>.
// Returns the files as they existed at the given point in time.
func (s *Server) handleFilesAtTime(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())

	atStr := r.URL.Query().Get("at")
	if atStr == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing required query param: at"})
		return
	}

	at, err := time.Parse(time.RFC3339, atStr)
	if err != nil {
		at, err = time.Parse(time.RFC3339Nano, atStr)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid at timestamp: must be ISO 8601 (e.g. 2026-03-20T15:00:00Z)"})
			return
		}
	}

	parentID := r.URL.Query().Get("parent_id")

	// When navigating inside a specific folder (parentID set), do not filter by owner:
	// files inside team folders or other users' shared folders belong to different owners.
	// At root level (parentID empty), restrict regular users to their own root folder.
	var ownerFilter string
	if parentID == "" && claims.Role != "admin" {
		ownerFilter = claims.UserID
	}

	files, err := s.db.ListFilesAtTime(parentID, ownerFilter, at)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not list files at time"})
		return
	}

	result := make([]fileAtTimeResponse, 0, len(files))
	for _, f := range files {
		size := f.Size
		if f.IsDir {
			if folderSize, err := s.db.GetFolderSize(f.ID); err == nil {
				size = folderSize
			}
		}
		result = append(result, fileAtTimeResponse{
			ID:          f.ID,
			Name:        f.Name,
			IsDir:       f.IsDir,
			Size:        size,
			VersionNum:  f.VersionNum,
			VersionID:   f.VersionID,
			ContentHash: f.ContentHash,
			UpdatedAt:   f.UpdatedAt,
		})
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"at":    at.UTC().Format(time.RFC3339),
		"files": result,
	})
}

// handleChangeDates handles GET /api/files/history/dates?parent_id=X.
// Returns a list of dates on which file versions were created.
func (s *Server) handleChangeDates(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	parentID := r.URL.Query().Get("parent_id")

	// When inside a specific folder, show all change dates regardless of owner
	// (covers team folders where files belong to other users).
	var ownerFilter string
	if parentID == "" && claims.Role != "admin" {
		ownerFilter = claims.UserID
	}
	dates, err := s.db.ListChangeDates(parentID, ownerFilter)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not list change dates"})
		return
	}

	dateStrs := make([]string, 0, len(dates))
	for _, d := range dates {
		dateStrs = append(dateStrs, d.Format("2006-01-02"))
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"dates": dateStrs})
}

// handleDownloadFolderAtTime handles GET /api/files/history/download?parent_id=X&at=<ISO8601>.
// Downloads all files in a folder as a ZIP archive, using the versions that existed at the given time.
func (s *Server) handleDownloadFolderAtTime(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())

	atStr := r.URL.Query().Get("at")
	if atStr == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing required query param: at"})
		return
	}
	at, err := time.Parse(time.RFC3339, atStr)
	if err != nil {
		at, err = time.Parse(time.RFC3339Nano, atStr)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid at timestamp"})
			return
		}
	}

	parentID := r.URL.Query().Get("parent_id")
	if parentID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "parent_id is required"})
		return
	}

	// Get the folder name for the ZIP filename
	folder, err := s.db.GetFileByID(parentID)
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "folder not found"})
		return
	}

	// Recursively collect all files in this folder at the given time
	type fileEntry struct {
		relativePath string
		contentHash  string
	}
	var entries []fileEntry

	var collectFiles func(folderID, prefix string) error
	collectFiles = func(folderID, prefix string) error {
		files, err := s.db.ListFilesAtTime(folderID, claims.UserID, at)
		if err != nil {
			return err
		}
		for _, f := range files {
			if f.IsDir {
				if err := collectFiles(f.ID, path.Join(prefix, f.Name)); err != nil {
					return err
				}
			} else if f.ContentHash != "" {
				entries = append(entries, fileEntry{
					relativePath: path.Join(prefix, f.Name),
					contentHash:  f.ContentHash,
				})
			}
		}
		return nil
	}

	if err := collectFiles(parentID, ""); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not collect files"})
		return
	}

	if len(entries) == 0 {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "no files found at this time"})
		return
	}

	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s-%s.zip"`, folder.Name, at.Format("2006-01-02")))

	zw := zip.NewWriter(w)
	defer zw.Close()

	for _, entry := range entries {
		fw, err := zw.Create(entry.relativePath)
		if err != nil {
			return
		}
		if err := s.store.Get(entry.contentHash, fw); err != nil {
			return
		}
	}
}

// handleRestoreFolderAtTime handles POST /api/files/history/restore.
// Restores all files in a folder to their versions at the given time.
func (s *Server) handleRestoreFolderAtTime(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())

	var req struct {
		ParentID string `json:"parent_id"`
		At       string `json:"at"`
	}
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	if req.ParentID == "" || req.At == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "parent_id and at are required"})
		return
	}

	at, err := time.Parse(time.RFC3339, req.At)
	if err != nil {
		at, err = time.Parse(time.RFC3339Nano, req.At)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid at timestamp"})
			return
		}
	}

	// Recursively restore all files
	restored := 0
	var restoreFiles func(folderID string) error
	restoreFiles = func(folderID string) error {
		files, err := s.db.ListFilesAtTime(folderID, claims.UserID, at)
		if err != nil {
			return err
		}
		for _, f := range files {
			if f.IsDir {
				if err := restoreFiles(f.ID); err != nil {
					return err
				}
			} else if f.VersionNum > 0 && f.ContentHash != "" {
				if err := s.db.UpdateFileContent(f.ID, f.ContentHash, f.Size); err != nil {
					return err
				}
				restored++
			}
		}
		return nil
	}

	if err := restoreFiles(req.ParentID); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not restore files"})
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"status":   "restored",
		"restored": restored,
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
