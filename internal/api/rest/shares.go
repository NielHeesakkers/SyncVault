package rest

import (
	"errors"
	"fmt"
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

func toShareLinkResponse(sl metadata.ShareLink, fileName string) shareLinkResponse {
	hasPwd := sl.PasswordHash != ""
	return shareLinkResponse{
		ID:                sl.ID,
		FileID:            sl.FileID,
		FileName:          fileName,
		Token:             sl.Token,
		HasPassword:       hasPwd,
		PasswordProtected: hasPwd,
		ExpiresAt:         sl.ExpiresAt,
		MaxDownloads:      sl.MaxDownloads,
		DownloadCount:     sl.DownloadCount,
		CreatedBy:         sl.CreatedBy,
		CreatedAt:         sl.CreatedAt,
	}
}

// enrichShareLinks resolves file names for a list of share links in a single pass.
func (s *Server) enrichShareLinks(links []metadata.ShareLink) []shareLinkResponse {
	// Collect unique file IDs.
	fileIDs := make(map[string]struct{}, len(links))
	for _, sl := range links {
		fileIDs[sl.FileID] = struct{}{}
	}
	// Batch-load file names.
	names := make(map[string]string, len(fileIDs))
	for id := range fileIDs {
		if f, err := s.db.GetFileByID(id); err == nil {
			names[id] = f.Name
		}
	}
	result := make([]shareLinkResponse, 0, len(links))
	for _, sl := range links {
		result = append(result, toShareLinkResponse(sl, names[sl.FileID]))
	}
	return result
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

	// Verify the file exists and the user owns it (or is admin).
	if _, ok := s.checkFileOwnership(w, r, fileID); !ok {
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

	fileName := ""
	if f, err := s.db.GetFileByID(sl.FileID); err == nil {
		fileName = f.Name
	}

	// Send share notification email (async — don't block response)
	if s.email != nil && s.email.Enabled() && fileName != "" {
		go func() {
			baseURL, _ := s.db.GetSetting("base_url")
			if baseURL == "" {
				baseURL = "https://" + r.Host
			}
			shareURL := fmt.Sprintf("%s/s/%s", baseURL, sl.Token)
			sharer, _ := s.db.GetUserByID(claims.UserID)
			sharerName := claims.Username
			if sharer != nil && sharer.DisplayName != "" {
				sharerName = sharer.DisplayName
			}
			// Notify the file owner if different from the sharer
			if f, err := s.db.GetFileByID(sl.FileID); err == nil && f.OwnerID != claims.UserID {
				if owner, err := s.db.GetUserByID(f.OwnerID); err == nil && owner.Email != "" {
					_ = s.email.SendShareNotification(owner.Email, sharerName, fileName, shareURL)
				}
			}
		}()
	}

	writeJSON(w, http.StatusCreated, toShareLinkResponse(*sl, fileName))
}

// handleListShares handles GET /api/files/{id}/shares.
func (s *Server) handleListShares(w http.ResponseWriter, r *http.Request) {
	fileID := chi.URLParam(r, "id")

	// Verify the file exists and the user owns it (or is admin).
	if _, ok := s.checkFileOwnership(w, r, fileID); !ok {
		return
	}

	links, err := s.db.ListShareLinks(fileID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not list share links"})
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"shares": s.enrichShareLinks(links)})
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

	writeJSON(w, http.StatusOK, map[string]interface{}{"shares": s.enrichShareLinks(links)})
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

	fn := ""
	if f, err := s.db.GetFileByID(sl.FileID); err == nil {
		fn = f.Name
	}
	writeJSON(w, http.StatusOK, toShareLinkResponse(*sl, fn))
}

// publicShareResponse is the JSON response for GET /s/{token}.
type publicShareResponse struct {
	Name        string     `json:"name"`
	Size        int64      `json:"size"`
	HasPassword bool       `json:"has_password"`
	Expired     bool       `json:"expired"`
	ExpiresAt   *time.Time `json:"expires_at,omitempty"`
}

// handlePublicShare handles GET /s/{token} — serves a download page or JSON.
func (s *Server) handlePublicShare(w http.ResponseWriter, r *http.Request) {
	token := chi.URLParam(r, "token")

	sl, err := s.db.GetShareLinkByToken(token)
	if err != nil {
		if errors.Is(err, metadata.ErrShareLinkNotFound) {
			http.Error(w, "Share link not found", http.StatusNotFound)
			return
		}
		http.Error(w, "Server error", http.StatusInternalServerError)
		return
	}

	f, err := s.db.GetFileByID(sl.FileID)
	if err != nil {
		http.Error(w, "Server error", http.StatusInternalServerError)
		return
	}

	expired := sl.ExpiresAt != nil && time.Now().UTC().After(*sl.ExpiresAt)

	// If client wants JSON (API call), return JSON
	if r.Header.Get("Accept") == "application/json" {
		writeJSON(w, http.StatusOK, publicShareResponse{
			Name:        f.Name,
			Size:        f.Size,
			HasPassword: sl.PasswordHash != "",
			Expired:     expired,
			ExpiresAt:   sl.ExpiresAt,
		})
		return
	}

	// Serve HTML download page
	fileSize := f.Size
	if f.IsDir {
		fileSize = f.FolderSize
	}
	sizeStr := formatBytesGo(fileSize)
	statusMsg := ""
	if expired {
		statusMsg = `<p style="color:#ef4444;font-weight:600;margin-bottom:16px;">This link has expired.</p>`
	} else if sl.MaxDownloads > 0 && sl.DownloadCount >= sl.MaxDownloads {
		statusMsg = `<p style="color:#ef4444;font-weight:600;margin-bottom:16px;">Download limit reached.</p>`
	}

	passwordField := ""
	if sl.PasswordHash != "" {
		passwordField = `<div style="margin-bottom:16px;">
			<label style="display:block;font-size:13px;color:#9ca3af;margin-bottom:6px;">Password required</label>
			<input type="password" id="share-password" placeholder="Enter password" style="width:100%;padding:10px 14px;background:#1f2937;border:1px solid #374151;border-radius:8px;color:#fff;font-size:14px;outline:none;" />
		</div>`
	}

	downloadBtn := ""
	if !expired && !(sl.MaxDownloads > 0 && sl.DownloadCount >= sl.MaxDownloads) {
		downloadBtn = fmt.Sprintf(`<button onclick="downloadFile()" style="width:100%%;padding:12px;background:#2563eb;color:#fff;border:none;border-radius:10px;font-size:14px;font-weight:600;cursor:pointer;transition:background 0.15s;" onmouseover="this.style.background='#1d4ed8'" onmouseout="this.style.background='#2563eb'">Download</button>`)
	}

	html := fmt.Sprintf(`<!DOCTYPE html>
<html><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>%s — SyncVault</title>
<style>*{margin:0;padding:0;box-sizing:border-box}body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:20px}</style>
</head><body>
<div style="background:#1e293b;border:1px solid #334155;border-radius:16px;padding:32px;max-width:400px;width:100%%;text-align:center;box-shadow:0 8px 32px rgba(0,0,0,0.4);">
	<div style="width:56px;height:56px;background:#1e3a5f;border-radius:14px;display:flex;align-items:center;justify-content:center;margin:0 auto 20px;">
		<svg width="24" height="24" fill="none" stroke="#60a5fa" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4M7 10l5 5 5-5M12 15V3"/></svg>
	</div>
	<h2 style="font-size:18px;font-weight:700;margin-bottom:6px;">%s</h2>
	<p style="font-size:13px;color:#64748b;margin-bottom:24px;">%s</p>
	%s
	%s
	%s
	<p style="font-size:11px;color:#475569;margin-top:20px;">Shared via <strong>SyncVault</strong></p>
</div>
<script>
function downloadFile() {
	const pw = document.getElementById('share-password');
	if (pw && pw.value) {
		// Password protected: use POST with fetch
		fetch('/s/%s/download', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({password:pw.value})})
		.then(r => {
			if (!r.ok) return r.json().then(d => { alert(d.error || 'Download failed'); throw new Error(); });
			return r.blob();
		})
		.then(blob => {
			const a = document.createElement('a');
			a.href = URL.createObjectURL(blob);
			a.download = '%s';
			a.click();
		})
		.catch(() => {});
	} else {
		// No password: direct streaming download via GET
		window.location.href = '/s/%s/download';
	}
}
</script>
</body></html>`, f.Name, f.Name, sizeStr, statusMsg, passwordField, downloadBtn, token, f.Name, token)

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write([]byte(html))
}

func formatBytesGo(b int64) string {
	switch {
	case b >= 1<<30:
		return fmt.Sprintf("%.1f GB", float64(b)/float64(1<<30))
	case b >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(b)/float64(1<<20))
	case b >= 1<<10:
		return fmt.Sprintf("%.1f KB", float64(b)/float64(1<<10))
	default:
		return fmt.Sprintf("%d B", b)
	}
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

	// Check password (only for POST with body).
	if sl.PasswordHash != "" {
		if r.Method == http.MethodGet {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "password required"})
			return
		}
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

	// Increment download count before streaming.
	if err := s.db.IncrementShareDownload(sl.ID); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not update download count"})
		return
	}

	if f.IsDir {
		// Download folder as ZIP
		w.Header().Set("Content-Type", "application/zip")
		w.Header().Set("Content-Disposition", `attachment; filename="`+f.Name+`.zip"`)
		s.streamFolderAsZip(w, f.ID, f.Name)
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
	w.Header().Set("Content-Disposition", `attachment; filename="`+f.Name+`"`)

	if err := s.store.GetDirect(f.ContentHash.String, w); err != nil {
		// Headers already sent; nothing to do.
		return
	}
}
