package rest

import (
	"archive/zip"
	"errors"
	"fmt"
	"log"
	"io"
	"net/http"
	"path"
	"strconv"
	"time"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
	"github.com/NielHeesakkers/SyncVault/internal/metadata"
	"github.com/go-chi/chi/v5"
)

// fileResponse is the JSON representation of a file metadata entry.
type fileResponse struct {
	ID             string    `json:"id"`
	ParentID       string    `json:"parent_id,omitempty"`
	Name           string    `json:"name"`
	IsDir          bool      `json:"is_dir"`
	Size           int64     `json:"size"`
	ContentHash    string    `json:"content_hash,omitempty"`
	MimeType       string    `json:"mime_type,omitempty"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
	RemovedLocally bool      `json:"removed_locally"`
}

// toFileResponse converts a metadata.File to a fileResponse.
func toFileResponse(f metadata.File) fileResponse {
	fr := fileResponse{
		ID:             f.ID,
		Name:           f.Name,
		IsDir:          f.IsDir,
		Size:           f.Size,
		CreatedAt:      f.CreatedAt,
		UpdatedAt:      f.UpdatedAt,
		RemovedLocally: f.RemovedLocally,
	}
	if f.ParentID.Valid {
		fr.ParentID = f.ParentID.String
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
	dirsOnly := r.URL.Query().Get("dirs_only") == "true"

	files, err := s.db.ListChildren(parentID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not list files"})
		return
	}

	// Non-admins only see their own files at root level.
	// folder_size is pre-computed and cached in the files table — no extra queries needed.
	var result []fileResponse
	for _, f := range files {
		if claims.Role != "admin" && parentID == "" && f.OwnerID != claims.UserID {
			continue
		}
		if dirsOnly && !f.IsDir {
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
// CreateFile already renames any existing file/folder with the same name before inserting.
// If a duplicate error still occurs (unlikely race), we handle it gracefully:
//   - For directories: find and return the existing active directory (idempotent).
//   - For files: return 409 Conflict.
func (s *Server) handleCreateFile(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())

	var req createFileRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	// Non-admin users cannot create files at root level — must be inside their user folder
	if req.ParentID == "" && claims.Role != "admin" {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "cannot create files at root level"})
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

	action := "create_file"
	if req.IsDir {
		action = "create_folder"
	}
	_ = s.db.LogActivity(claims.UserID, action, "file", f.ID, req.Name, r.RemoteAddr)

	writeJSON(w, http.StatusCreated, toFileResponse(*f))
}

// handleUploadFile handles multipart file upload, stores content, and creates metadata + version.
// Streams directly from the request body — no memory buffering of the file.
func (s *Server) handleUploadFile(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())

	reader, err := r.MultipartReader()
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "could not parse multipart"})
		return
	}

	var parentID string
	var filename string
	var mimeType string
	var contentHash string
	var size int64
	var fileProcessed bool

	for {
		part, err := reader.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "could not read multipart"})
			return
		}

		switch part.FormName() {
		case "parent_id":
			b, _ := io.ReadAll(part)
			parentID = string(b)
		case "file":
			filename = part.FileName()
			// Read first 512 bytes for MIME detection
			buf := make([]byte, 512)
			n, _ := part.Read(buf)
			mimeType = http.DetectContentType(buf[:n])

			// Pipe: stream the already-read bytes + rest of part directly into storage
			pr, pw := io.Pipe()
			errCh := make(chan error, 1)
			go func() {
				var putErr error
				contentHash, size, putErr = s.store.Put(pr)
				errCh <- putErr
			}()

			// Write the already-read bytes first
			if _, err := pw.Write(buf[:n]); err != nil {
				pw.CloseWithError(err)
				<-errCh
				writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not store file"})
				return
			}
			// Stream the rest
			if _, err := io.Copy(pw, part); err != nil {
				pw.CloseWithError(err)
				<-errCh
				writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not store file"})
				return
			}
			pw.Close()

			if putErr := <-errCh; putErr != nil {
				writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not store file"})
				return
			}
			fileProcessed = true
		}
		part.Close()
	}

	if !fileProcessed {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing file field"})
		return
	}

	// Create file metadata entry.
	f, err := s.db.CreateFile(parentID, claims.UserID, filename, false, size, contentHash, mimeType)
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

// handleGetFile handles GET /api/files/{id} — get single file metadata.
func (s *Server) handleGetFile(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	f, ok := s.checkFileOwnership(w, r, id)
	if !ok {
		return
	}

	writeJSON(w, http.StatusOK, toFileResponse(*f))
}

// handleUpdateFile handles PUT /api/files/{id} — rename or move.
func (s *Server) handleUpdateFile(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	f, ok := s.checkFileOwnership(w, r, id)
	if !ok {
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

	if _, ok := s.checkFileOwnership(w, r, id); !ok {
		return
	}

	f, _ := s.db.GetFileByID(id)

	if err := s.db.SoftDeleteFile(id); err != nil {
		if errors.Is(err, metadata.ErrFileNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "file not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not delete file"})
		return
	}

	claims := auth.GetClaims(r.Context())
	name := id
	if f != nil {
		name = f.Name
	}
	_ = s.db.LogActivity(claims.UserID, "delete", "file", id, name, r.RemoteAddr)

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

// handlePurgeTrash handles DELETE /api/trash — permanently delete all trashed files.
// Admin purges ALL trash (including orphaned items). Regular users purge only their own.
func (s *Server) handlePurgeTrash(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	var count int64
	var err error
	if claims.Role == "admin" {
		count, err = s.db.PurgeAllTrash()
	} else {
		count, err = s.db.PurgeUserTrash(claims.UserID)
	}
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not purge trash"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"deleted": count})
}

// handlePermanentlyDeleteFile handles DELETE /api/trash/{id} — permanently delete one trashed file.
func (s *Server) handlePermanentlyDeleteFile(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	if _, ok := s.checkFileOwnership(w, r, id); !ok {
		return
	}
	if err := s.db.PermanentlyDeleteFile(id); err != nil {
		if errors.Is(err, metadata.ErrFileNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "file not found in trash"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not delete file"})
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleListTrash handles GET /api/trash — list trashed files (admin sees all users).
func (s *Server) handleListTrash(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())

	var files []metadata.File
	var err error
	if claims.Role == "admin" {
		files, err = s.db.ListAllTrashedFiles()
	} else {
		files, err = s.db.ListTrashedFiles(claims.UserID)
	}
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
	ID             string  `json:"id"`
	Name           string  `json:"name"`
	ParentID       *string `json:"parent_id"`
	IsDir          bool    `json:"is_dir"`
	Size           int64   `json:"size"`
	ContentHash    string  `json:"content_hash,omitempty"`
	UpdatedAt      string  `json:"updated_at"`
	DeletedAt      *string `json:"deleted_at"`
	RemovedLocally bool    `json:"removed_locally"`
}

// toChangeResponse converts a metadata.File to a changeResponse.
func toChangeResponse(f metadata.File) changeResponse {
	cr := changeResponse{
		ID:             f.ID,
		Name:           f.Name,
		IsDir:          f.IsDir,
		Size:           f.Size,
		UpdatedAt:      f.UpdatedAt.UTC().Format(time.RFC3339),
		RemovedLocally: f.RemovedLocally,
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

	since, err := parseTimestamp(sinceStr)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid since timestamp: must be ISO 8601 (e.g. 2026-03-21T15:00:00Z)"})
		return
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

// handleListChangesV2 handles GET /api/changes/v2?since_rank=<int64>.
// Uses a monotonic rank counter instead of timestamps for reliable change tracking.
// Returns all files with change_rank > since_rank, including soft-deleted files.
func (s *Server) handleListChangesV2(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())

	sinceRankStr := r.URL.Query().Get("since_rank")
	sinceRank, _ := strconv.ParseInt(sinceRankStr, 10, 64)

	changes, currentRank, err := s.db.ListChangesByRank(sinceRank, claims.UserID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not list changes"})
		return
	}

	result := make([]changeResponse, 0, len(changes))
	for _, f := range changes {
		result = append(result, toChangeResponse(f))
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"changes":      result,
		"current_rank": currentRank,
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

	at, err := parseTimestamp(atStr)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid at timestamp: must be ISO 8601 (e.g. 2026-03-20T15:00:00Z)"})
		return
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
	at, err := parseTimestamp(atStr)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid at timestamp"})
		return
	}

	parentID := r.URL.Query().Get("parent_id")
	if parentID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "parent_id is required"})
		return
	}

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

// streamFolderAsZip writes all files under a folder as a ZIP stream.
func (s *Server) streamFolderAsZip(w http.ResponseWriter, folderID, folderName string) {
	files, err := s.db.ListFilesRecursive(folderID, "", true)
	if err != nil {
		return
	}

	zw := zip.NewWriter(w)
	defer zw.Close()

	for _, f := range files {
		if f.IsDir || !f.ContentHash.Valid || f.ContentHash.String == "" {
			continue
		}
		fw, err := zw.Create(f.RelativePath)
		if err != nil {
			return
		}
		if err := s.store.Get(f.ContentHash.String, fw); err != nil {
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

	at, err := parseTimestamp(req.At)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid at timestamp"})
		return
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

// handleSetRemovedLocally handles PUT /api/files/{id}/removed-locally.
// Accepts {"removed": true/false} and updates the removed_locally flag on the file.
func (s *Server) handleSetRemovedLocally(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	if _, ok := s.checkFileOwnership(w, r, id); !ok {
		return
	}

	var req struct {
		Removed bool `json:"removed"`
	}
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	var err error
	if req.Removed {
		err = s.db.MarkRemovedLocally(id)
	} else {
		err = s.db.UnmarkRemovedLocally(id)
	}
	if err != nil {
		if errors.Is(err, metadata.ErrFileNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "file not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not update file"})
		return
	}

	f, err := s.db.GetFileByID(id)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get updated file"})
		return
	}

	writeJSON(w, http.StatusOK, toFileResponse(*f))
}

// handleDownloadFile streams a file's content from storage.
func (s *Server) handleDownloadFile(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	f, ok := s.checkFileOwnership(w, r, id)
	if !ok {
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
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, sanitizeFilename(f.Name)))

	claims := auth.GetClaims(r.Context())
	_ = s.db.LogActivity(claims.UserID, "download", "file", id, f.Name+" ("+formatSize(f.Size)+")", r.RemoteAddr)

	if err := s.store.Get(f.ContentHash.String, w); err != nil {
		// Headers already sent; we can't write a JSON error at this point.
		return
	}
}

// handlePreviewFile handles GET /api/files/{id}/preview — serves inline file content.
func (s *Server) handlePreviewFile(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	f, ok := s.checkFileOwnership(w, r, id)
	if !ok {
		return
	}

	if f.IsDir {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "cannot preview a directory"})
		return
	}

	if !f.ContentHash.Valid || f.ContentHash.String == "" {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]string{"error": "file has no content"})
		return
	}

	// Only allow preview for files with a known mime type.
	if !f.MimeType.Valid || f.MimeType.String == "" {
		writeJSON(w, http.StatusUnsupportedMediaType, map[string]string{"error": "unknown file type"})
		return
	}

	w.Header().Set("Content-Type", f.MimeType.String)
	w.Header().Set("Content-Disposition", "inline")

	if err := s.store.Get(f.ContentHash.String, w); err != nil {
		// Headers already sent; we can't write a JSON error at this point.
		return
	}
}

// handleUserActivity handles GET /api/activity?limit=N.
// Returns activity log entries scoped to the authenticated user.
func (s *Server) handleUserActivity(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	q := metadata.ActivityQuery{UserID: claims.UserID}

	if limitStr := r.URL.Query().Get("limit"); limitStr != "" {
		if limit, err := strconv.Atoi(limitStr); err == nil && limit > 0 {
			q.Limit = limit
		}
	}
	if q.Limit <= 0 {
		q.Limit = 20
	}

	entries, err := s.db.QueryActivity(q)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not query activity"})
		return
	}

	if entries == nil {
		entries = []metadata.ActivityEntry{}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"activity": entries})
}

// handleSearchFiles handles GET /api/files/search?q=<query>.
// Returns files matching the search query for the authenticated user.
func (s *Server) handleSearchFiles(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	q := r.URL.Query().Get("q")
	if q == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "query parameter 'q' is required"})
		return
	}
	files, err := s.db.SearchFiles(claims.UserID, q)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "search failed"})
		return
	}
	result := make([]fileResponse, 0, len(files))
	for _, f := range files {
		result = append(result, toFileResponse(f))
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"files": result})
}

// handleCheckHashes accepts a list of content hashes and returns which ones already exist on the server.
// Returns: {"existing": ["abc123", "def456"]} — only hashes that exist.
func (s *Server) handleCheckHashes(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())

	var req struct {
		Hashes []string `json:"hashes"`
	}
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	log.Printf("check-hashes: user=%s hashes=%d", claims.Username, len(req.Hashes))
	if len(req.Hashes) == 0 {
		writeJSON(w, http.StatusOK, map[string]interface{}{"existing": []string{}})
		return
	}

	existingMap, err := s.db.CheckFileHashes(claims.UserID, req.Hashes)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not check hashes"})
		return
	}

	var existingList []string
	for hash, exists := range existingMap {
		if exists {
			existingList = append(existingList, hash)
		}
	}
	if existingList == nil {
		existingList = []string{}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"existing": existingList})
}

// handleLockFile handles POST /api/files/{id}/lock — lock a file for editing.
func (s *Server) handleLockFile(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	id := chi.URLParam(r, "id")

	var req struct {
		Device string `json:"device"`
	}
	_ = readJSON(r, &req)

	lock, err := s.db.LockFile(id, claims.UserID, claims.Username, req.Device)
	if err != nil {
		writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"file_id":    lock.FileID,
		"user_id":    lock.UserID,
		"username":   lock.Username,
		"device":     lock.Device,
		"locked_at":  lock.LockedAt.Format(time.RFC3339),
		"expires_at": lock.ExpiresAt.Format(time.RFC3339),
	})
}

// handleUnlockFile handles DELETE /api/files/{id}/lock — unlock a file.
func (s *Server) handleUnlockFile(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	id := chi.URLParam(r, "id")

	if err := s.db.UnlockFile(id, claims.UserID); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not unlock file"})
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

// handleGetFileLock handles GET /api/files/{id}/lock — check lock status.
func (s *Server) handleGetFileLock(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	lock, err := s.db.GetFileLock(id)
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]interface{}{"locked": false})
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"locked":     true,
		"file_id":    lock.FileID,
		"user_id":    lock.UserID,
		"username":   lock.Username,
		"device":     lock.Device,
		"locked_at":  lock.LockedAt.Format(time.RFC3339),
		"expires_at": lock.ExpiresAt.Format(time.RFC3339),
	})
}

// handleFileTree returns a flat list of all files (recursively) under a given folder.
// Used by the sync client to compare local vs remote without multiple API calls.
// Accepts folder_id either as a URL path parameter ({id}) or as a query parameter.
func (s *Server) handleFileTree(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	folderID := chi.URLParam(r, "id")
	if folderID == "" {
		folderID = r.URL.Query().Get("folder_id")
	}
	if folderID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "folder_id required"})
		return
	}

	files, err := s.db.ListFilesRecursive(folderID, claims.UserID, claims.Role == "admin")
	if err != nil {
		log.Printf("handleFileTree error for folder %s: %v", folderID, err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not list file tree"})
		return
	}

	type treeEntry struct {
		ID           string `json:"id"`
		Name         string `json:"name"`
		RelativePath string `json:"relative_path"`
		IsDir        bool   `json:"is_dir"`
		Size         int64  `json:"size"`
		ContentHash  string `json:"content_hash,omitempty"`
		RemovedLocally bool `json:"removed_locally"`
	}

	result := make([]treeEntry, 0, len(files))
	for _, f := range files {
		entry := treeEntry{
			ID:           f.ID,
			Name:         f.Name,
			RelativePath: f.RelativePath,
			IsDir:        f.IsDir,
			Size:         f.Size,
			RemovedLocally: f.RemovedLocally,
		}
		if f.ContentHash.Valid {
			entry.ContentHash = f.ContentHash.String
		}
		result = append(result, entry)
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"files": result})
}
