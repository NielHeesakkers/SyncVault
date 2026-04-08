package rest

import (
	"errors"
	"net/http"
	"time"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
	"github.com/NielHeesakkers/SyncVault/internal/metadata"
	"github.com/go-chi/chi/v5"
)

// shareLinkResponse is the JSON representation of a share link.
type shareLinkResponse struct {
	ID                string     `json:"id"`
	FileID            string     `json:"file_id"`
	FileName          string     `json:"file_name,omitempty"`
	Token             string     `json:"token"`
	HasPassword       bool       `json:"has_password"`
	PasswordProtected bool       `json:"password_protected"`
	ExpiresAt         *time.Time `json:"expires_at,omitempty"`
	MaxDownloads      int        `json:"max_downloads"`
	DownloadCount     int        `json:"download_count"`
	CreatedBy         string     `json:"created_by"`
	CreatedAt         time.Time  `json:"created_at"`
}

func (s *Server) toShareLinkResponseWithName(sl metadata.ShareLink) shareLinkResponse {
	hasPwd := sl.PasswordHash != ""
	r := shareLinkResponse{
		ID:                sl.ID,
		FileID:            sl.FileID,
		Token:             sl.Token,
		HasPassword:       hasPwd,
		PasswordProtected: hasPwd,
		ExpiresAt:         sl.ExpiresAt,
		MaxDownloads:      sl.MaxDownloads,
		DownloadCount:     sl.DownloadCount,
		CreatedBy:         sl.CreatedBy,
		CreatedAt:         sl.CreatedAt,
	}
	if f, err := s.db.GetFileByID(sl.FileID); err == nil {
		r.FileName = f.Name
	}
	return r
}

// createShareRequest is the body for POST /api/files/{id}/shares.
type createShareRequest struct {
	Password     string     `json:"password"`
	ExpiresAt    *time.Time `json:"expires_at"`
	MaxDownloads int        `json:"max_downloads"`
}

// handleCreateShare handles POST /api/files/{id}/shares.
func (s *Server) handleCreateShare(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	fileID := chi.URLParam(r, "id")

	// Ensure the file exists.
	if _, err := s.db.GetFileByID(fileID); err != nil {
		if errors.Is(err, metadata.ErrFileNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "file not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get file"})
		return
	}

	var req createShareRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	passwordHash := ""
	if req.Password != "" {
		var err error
		passwordHash, err = auth.HashPassword(req.Password)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not hash password"})
			return
		}
	}

	sl, err := s.db.CreateShareLink(fileID, claims.UserID, passwordHash, req.ExpiresAt, req.MaxDownloads)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not create share link"})
		return
	}

	writeJSON(w, http.StatusCreated, s.toShareLinkResponseWithName(*sl))
}

// handleListShares handles GET /api/files/{id}/shares.
func (s *Server) handleListShares(w http.ResponseWriter, r *http.Request) {
	fileID := chi.URLParam(r, "id")

	// Ensure the file exists.
	if _, err := s.db.GetFileByID(fileID); err != nil {
		if errors.Is(err, metadata.ErrFileNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "file not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get file"})
		return
	}

	links, err := s.db.ListShareLinks(fileID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not list share links"})
		return
	}

	result := make([]shareLinkResponse, 0, len(links))
	for _, sl := range links {
		result = append(result, s.toShareLinkResponseWithName(sl))
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"shares": result})
}

// handleDeleteShare handles DELETE /api/shares/{id}.
func (s *Server) handleDeleteShare(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	if err := s.db.DeleteShareLink(id); err != nil {
		if errors.Is(err, metadata.ErrShareLinkNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "share link not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not delete share link"})
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

// handleListMyShares handles GET /api/shares/mine.
func (s *Server) handleListMyShares(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())

	links, err := s.db.ListShareLinksByUser(claims.UserID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not list share links"})
		return
	}

	result := make([]shareLinkResponse, 0, len(links))
	for _, sl := range links {
		result = append(result, s.toShareLinkResponseWithName(sl))
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"shares": result})
}

// toggleShareRequest is the body for PUT /api/shares/{id}/toggle.
type toggleShareRequest struct {
	Disabled bool `json:"disabled"`
}

// handleToggleShare handles PUT /api/shares/{id}/toggle — enables or disables a share link.
func (s *Server) handleToggleShare(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	sl, err := s.db.GetShareLinkByID(id)
	if err != nil {
		if errors.Is(err, metadata.ErrShareLinkNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "share link not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get share link"})
		return
	}

	// Only the creator (or admin) may toggle.
	claims := auth.GetClaims(r.Context())
	if sl.CreatedBy != claims.UserID && claims.Role != "admin" {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "access denied"})
		return
	}

	var req toggleShareRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	if err := s.db.SetShareLinkDisabled(id, req.Disabled); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not update share link"})
		return
	}

	// Re-fetch and return updated share.
	sl, err = s.db.GetShareLinkByID(id)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get share link"})
		return
	}

	writeJSON(w, http.StatusOK, s.toShareLinkResponseWithName(*sl))
}

// publicShareResponse is the JSON response for GET /s/{token}.
type publicShareResponse struct {
	Name        string     `json:"name"`
	Size        int64      `json:"size"`
	HasPassword bool       `json:"has_password"`
	Expired     bool       `json:"expired"`
	ExpiresAt   *time.Time `json:"expires_at,omitempty"`
}

// handlePublicShare handles GET /s/{token} — returns public share info.
func (s *Server) handlePublicShare(w http.ResponseWriter, r *http.Request) {
	token := chi.URLParam(r, "token")

	sl, err := s.db.GetShareLinkByToken(token)
	if err != nil {
		if errors.Is(err, metadata.ErrShareLinkNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "share link not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get share link"})
		return
	}

	f, err := s.db.GetFileByID(sl.FileID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get file"})
		return
	}

	expired := sl.ExpiresAt != nil && time.Now().UTC().After(*sl.ExpiresAt)

	writeJSON(w, http.StatusOK, publicShareResponse{
		Name:        f.Name,
		Size:        f.Size,
		HasPassword: sl.PasswordHash != "",
		Expired:     expired,
		ExpiresAt:   sl.ExpiresAt,
	})
}

// publicDownloadRequest is the body for POST /s/{token}/download.
type publicDownloadRequest struct {
	Password string `json:"password"`
}

// handlePublicDownload handles POST /s/{token}/download — streams file content.
func (s *Server) handlePublicDownload(w http.ResponseWriter, r *http.Request) {
	token := chi.URLParam(r, "token")

	sl, err := s.db.GetShareLinkByToken(token)
	if err != nil {
		if errors.Is(err, metadata.ErrShareLinkNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "share link not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get share link"})
		return
	}

	// Check expiry.
	if sl.ExpiresAt != nil && time.Now().UTC().After(*sl.ExpiresAt) {
		writeJSON(w, http.StatusGone, map[string]string{"error": "share link has expired"})
		return
	}

	// Check download limit.
	if sl.MaxDownloads > 0 && sl.DownloadCount >= sl.MaxDownloads {
		writeJSON(w, http.StatusGone, map[string]string{"error": "download limit reached"})
		return
	}

	// Check password.
	if sl.PasswordHash != "" {
		var req publicDownloadRequest
		if err := readJSON(r, &req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
			return
		}
		if !auth.CheckPassword(req.Password, sl.PasswordHash) {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid password"})
			return
		}
	}

	f, err := s.db.GetFileByID(sl.FileID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get file"})
		return
	}

	if !f.ContentHash.Valid || f.ContentHash.String == "" {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]string{"error": "file has no content"})
		return
	}

	// Increment download count before streaming.
	if err := s.db.IncrementShareDownload(sl.ID); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not update download count"})
		return
	}

	mimeType := "application/octet-stream"
	if f.MimeType.Valid && f.MimeType.String != "" {
		mimeType = f.MimeType.String
	}

	w.Header().Set("Content-Type", mimeType)
	w.Header().Set("Content-Disposition", `attachment; filename="`+f.Name+`"`)

	if err := s.store.Get(f.ContentHash.String, w); err != nil {
		// Headers already sent; nothing to do.
		return
	}
}
