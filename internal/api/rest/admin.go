package rest

import (
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
	"github.com/NielHeesakkers/SyncVault/internal/metadata"
	"github.com/NielHeesakkers/SyncVault/internal/token"
	"github.com/go-chi/chi/v5"
)

// handleAdminGetSettings handles GET /api/admin/settings.
func (s *Server) handleAdminGetSettings(w http.ResponseWriter, r *http.Request) {
	settings, err := s.db.GetAllSettings()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not load settings"})
		return
	}
	writeJSON(w, http.StatusOK, settings)
}

// handleAdminPutSettings handles PUT /api/admin/settings.
func (s *Server) handleAdminPutSettings(w http.ResponseWriter, r *http.Request) {
	var incoming map[string]string
	if err := readJSON(r, &incoming); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	for k, v := range incoming {
		if err := s.db.SetSetting(k, v); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not save setting: " + k})
			return
		}
	}

	// Reload SMTP config from DB and apply to email service.
	if s.email != nil {
		smtpSettings, err := s.db.GetSettingsWithPrefix("smtp.")
		if err == nil {
			s.email.UpdateFromSettings(smtpSettings)
		}
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "settings saved"})
}

// handleAdminTestSMTP handles POST /api/admin/settings/test-smtp.
// It tests the SMTP connection without sending an email.
func (s *Server) handleAdminTestSMTP(w http.ResponseWriter, r *http.Request) {
	if s.email == nil || !s.email.Enabled() {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "SMTP is not enabled — save your settings first"})
		return
	}

	result := s.email.TestConnection()
	if result.Error != "" {
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"success": false,
			"error":   result.Error,
			"host":    result.Host,
			"port":    result.Port,
		})
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"host":    result.Host,
		"port":    result.Port,
		"message": "SMTP connection successful — server is reachable and credentials are valid",
	})
}

// handleAdminTestEmail handles POST /api/admin/settings/test-email.
func (s *Server) handleAdminTestEmail(w http.ResponseWriter, r *http.Request) {
	if s.email == nil || !s.email.Enabled() {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "SMTP is not enabled"})
		return
	}

	var body struct {
		Email string `json:"email"`
	}
	if err := readJSON(r, &body); err != nil || body.Email == "" {
		// Fall back to the logged-in admin's email if no body provided.
		claims := auth.GetClaims(r.Context())
		user, err := s.db.GetUserByID(claims.UserID)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not load user"})
			return
		}
		body.Email = user.Email
	}

	if err := s.email.SendTestEmail(body.Email); err != nil {
		log.Printf("admin: test email failed: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to send test email: " + err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "test email sent to " + body.Email})
}

// adminUserResponse is the JSON representation of a user with storage stats.
type adminUserResponse struct {
	ID          string    `json:"id"`
	Username    string    `json:"username"`
	Email       string    `json:"email"`
	Role        string    `json:"role"`
	QuotaBytes  int64     `json:"quota_bytes"`
	StorageUsed int64     `json:"storage_used"`
	HasToken    bool      `json:"has_token"`
	CreatedAt   time.Time `json:"created_at"`
	UpdatedAt   time.Time `json:"updated_at"`
}

// handleAdminListUsers handles GET /api/admin/users.
func (s *Server) handleAdminListUsers(w http.ResponseWriter, r *http.Request) {
	users, err := s.db.ListUsers()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not list users"})
		return
	}

	result := make([]adminUserResponse, 0, len(users))
	for _, u := range users {
		used, err := s.db.StorageUsedByUser(u.ID)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not compute storage usage"})
			return
		}
		hasToken := s.db.HasConnectionToken(u.ID)
		result = append(result, adminUserResponse{
			ID:          u.ID,
			Username:    u.Username,
			Email:       u.Email,
			Role:        u.Role,
			QuotaBytes:  u.QuotaBytes,
			StorageUsed: used,
			HasToken:    hasToken,
			CreatedAt:   u.CreatedAt,
			UpdatedAt:   u.UpdatedAt,
		})
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"users": result})
}

// updateUserRequest is the body for PUT /api/admin/users/{id}.
type updateUserRequest struct {
	Email      string `json:"email"`
	Role       string `json:"role"`
	QuotaBytes *int64 `json:"quota_bytes"`
}

// handleAdminUpdateUser handles PUT /api/admin/users/{id}.
func (s *Server) handleAdminUpdateUser(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	user, err := s.db.GetUserByID(id)
	if err != nil {
		if errors.Is(err, metadata.ErrUserNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "user not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get user"})
		return
	}

	var req updateUserRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	if req.Email != "" {
		user.Email = req.Email
	}
	if req.Role != "" {
		user.Role = req.Role
	}
	if req.QuotaBytes != nil {
		user.QuotaBytes = *req.QuotaBytes
	}

	if err := s.db.UpdateUser(user); err != nil {
		if errors.Is(err, metadata.ErrDuplicateUser) {
			writeJSON(w, http.StatusConflict, map[string]string{"error": "email already exists"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not update user"})
		return
	}

	writeJSON(w, http.StatusOK, adminUserResponse{
		ID:         user.ID,
		Username:   user.Username,
		Email:      user.Email,
		Role:       user.Role,
		QuotaBytes: user.QuotaBytes,
		CreatedAt:  user.CreatedAt,
		UpdatedAt:  user.UpdatedAt,
	})
}

// handleAdminTransferUser handles POST /api/admin/users/{id}/transfer.
// Transfers a user's root folder to another user's home folder.
func (s *Server) handleAdminTransferUser(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	var req struct {
		UserID string `json:"user_id"`
	}
	if err := readJSON(r, &req); err != nil || req.UserID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "user_id is required"})
		return
	}

	// Find source user's root folder
	srcRoot, err := s.db.GetUserRootFolder(id)
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "source user has no files"})
		return
	}

	// Find target user's root folder
	dstRoot, err := s.db.GetUserRootFolder(req.UserID)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "target user has no home folder"})
		return
	}

	// Move source root folder into target's home (becomes a subfolder)
	// and transfer ownership of ALL files recursively
	_ = s.db.MoveFile(srcRoot.ID, dstRoot.ID, srcRoot.Name)
	_ = s.db.TransferAllFiles(id, req.UserID)

	writeJSON(w, http.StatusOK, map[string]string{"status": "transferred"})
}

// handleAdminDeleteUser handles DELETE /api/admin/users/{id}.
func (s *Server) handleAdminDeleteUser(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	if err := s.db.DeleteUser(id); err != nil {
		if errors.Is(err, metadata.ErrUserNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "user not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not delete user"})
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

// resetPasswordRequest is the body for POST /api/admin/users/{id}/reset-password.
type resetPasswordRequest struct {
	Password string `json:"password"`
}

// handleAdminResetPassword handles POST /api/admin/users/{id}/reset-password.
func (s *Server) handleAdminResetPassword(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	user, err := s.db.GetUserByID(id)
	if err != nil {
		if errors.Is(err, metadata.ErrUserNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "user not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get user"})
		return
	}

	var req resetPasswordRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	if req.Password == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "password is required"})
		return
	}

	hashed, err := auth.HashPassword(req.Password)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not hash password"})
		return
	}

	user.Password = hashed
	if err := s.db.UpdateUser(user); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not update password"})
		return
	}

	// Invalidate all existing tokens so the user is logged out everywhere
	_ = s.db.InvalidateTokens(user.ID)

	// Send password reset email; log but do not fail on error.
	if s.email != nil && s.email.Enabled() {
		if err := s.email.SendPasswordReset(user.Email, user.Username, req.Password); err != nil {
			log.Printf("email: failed to send password reset email to %s: %v", user.Email, err)
		}
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "password updated"})
}

// storageOverviewResponse is the JSON response for GET /api/admin/storage.
type storageOverviewResponse struct {
	TotalUsers   int   `json:"total_users"`
	Used         int64 `json:"used"`
	Total        int64 `json:"total"`
	Available    int64 `json:"available"`
	TrashSize    int64 `json:"trash_size"`
	VersionsSize int64 `json:"versions_size"`
}

// handleAdminStorage handles GET /api/admin/storage.
func (s *Server) handleAdminStorage(w http.ResponseWriter, r *http.Request) {
	users, err := s.db.ListUsers()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not list users"})
		return
	}

	var totalUsed, totalQuota int64
	for _, u := range users {
		used, err := s.db.StorageUsedByUser(u.ID)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not compute storage usage"})
			return
		}
		totalUsed += used
		totalQuota += u.QuotaBytes
	}

	trashSize := s.db.TotalTrashSize()
	versionsSize := s.db.TotalVersionsSize()

	// Use actual disk space if no quotas are configured
	diskTotal, diskAvail := s.store.DiskSpace()
	if totalQuota == 0 && diskTotal > 0 {
		totalQuota = diskTotal
	}
	available := totalQuota - totalUsed
	if diskAvail > 0 && (available <= 0 || available > diskAvail) {
		available = diskAvail
	}

	writeJSON(w, http.StatusOK, storageOverviewResponse{
		TotalUsers:   len(users),
		Used:         totalUsed,
		Total:        totalQuota,
		Available:    available,
		TrashSize:    trashSize,
		VersionsSize: versionsSize,
	})
}

// storageUserEntry is a per-user storage entry for GET /api/admin/storage/users.
type storageUserEntry struct {
	ID           string `json:"id"`
	Username     string `json:"username"`
	StorageUsed  int64  `json:"storage_used"`
	StorageQuota int64  `json:"storage_quota,omitempty"`
}

// handleAdminStorageUsers handles GET /api/admin/storage/users.
func (s *Server) handleAdminStorageUsers(w http.ResponseWriter, r *http.Request) {
	users, err := s.db.ListUsers()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not list users"})
		return
	}

	result := make([]storageUserEntry, 0, len(users))
	for _, u := range users {
		used, err := s.db.StorageUsedByUser(u.ID)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not compute storage usage"})
			return
		}
		result = append(result, storageUserEntry{
			ID:           u.ID,
			Username:     u.Username,
			StorageUsed:  used,
			StorageQuota: u.QuotaBytes,
		})
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"users": result})
}

// storageFolderEntry is a per-folder storage entry for GET /api/admin/storage/folders.
type storageFolderEntry struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Size int64  `json:"size"`
}

// handleAdminStorageFolders handles GET /api/admin/storage/folders.
func (s *Server) handleAdminStorageFolders(w http.ResponseWriter, r *http.Request) {
	folders, err := s.db.ListTopFoldersBySize()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not list folder sizes"})
		return
	}

	result := make([]storageFolderEntry, 0, len(folders))
	for _, f := range folders {
		result = append(result, storageFolderEntry{
			ID:   f.ID,
			Name: f.Name,
			Size: f.Size,
		})
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"folders": result})
}

// handleDownloadToken handles GET /api/admin/users/{id}/token.
// It returns the encrypted .syncvault file for the specified user.
func (s *Server) handleDownloadToken(w http.ResponseWriter, r *http.Request) {
	userID := chi.URLParam(r, "id")

	user, err := s.db.GetUserByID(userID)
	if err != nil {
		if errors.Is(err, metadata.ErrUserNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "user not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get user"})
		return
	}

	data, err := s.db.GetConnectionToken(userID)
	if err != nil {
		if errors.Is(err, metadata.ErrConnectionTokenNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "no connection token for this user"})
			return
		}
		if errors.Is(err, metadata.ErrConnectionTokenUsed) {
			writeJSON(w, http.StatusGone, map[string]string{"error": "token already used — click refresh to generate a new one"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not retrieve token"})
		return
	}

	// Mark token as used (one-time download)
	_ = s.db.MarkConnectionTokenUsed(userID)

	filename := fmt.Sprintf("%s.syncvault", user.Username)
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%q", filename))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

// handleRefreshToken handles POST /api/admin/users/{id}/token/refresh.
// It generates a new connection token and PIN, emails the PIN, and stores the token.
func (s *Server) handleRefreshToken(w http.ResponseWriter, r *http.Request) {
	userID := chi.URLParam(r, "id")

	user, err := s.db.GetUserByID(userID)
	if err != nil {
		if errors.Is(err, metadata.ErrUserNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "user not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get user"})
		return
	}

	// Get the base URL from settings
	baseURL, _ := s.db.GetSetting("base_url")
	if baseURL == "" {
		baseURL = "https://" + r.Host
	}

	// Generate new PIN and encrypt credentials
	pin := token.GeneratePIN()
	connData := token.ConnectionData{
		ServerURL: baseURL,
		Username:  user.Username,
		Password:  "", // Password is not stored — user must know it
	}

	// For refresh, we can't include the password since we don't have it.
	// Instead, the token file just contains server URL and username.
	encrypted, err := token.Encrypt(connData, pin)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not encrypt token"})
		return
	}

	// Save token (resets used flag)
	if err := s.db.SaveConnectionToken(userID, encrypted); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not save token"})
		return
	}

	// Email the PIN
	if s.email != nil && s.email.Enabled() {
		_ = s.email.SendWelcome(user.Email, user.Username, "(your existing password)", pin)
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "message": "New token generated and PIN emailed"})
}

// cleanupRequest is the body for POST /api/admin/cleanup.
type cleanupRequest struct {
	BeforeDate      string `json:"before_date"`      // RFC3339 date
	IncludeVersions bool   `json:"include_versions"`  // also delete old versions
	OnlyDeleted     bool   `json:"only_deleted"`      // only files already in trash
}

// handleAdminCleanup handles POST /api/admin/cleanup.
func (s *Server) handleAdminCleanup(w http.ResponseWriter, r *http.Request) {
	var req cleanupRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	if req.BeforeDate == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "before_date is required"})
		return
	}

	beforeDate, err := parseTimestamp(req.BeforeDate)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "before_date must be RFC3339 or YYYY-MM-DD"})
		return
	}

	fileCount, versionCount, freedBytes, err := s.db.ExecuteCleanup(beforeDate, req.IncludeVersions, req.OnlyDeleted)
	if err != nil {
		log.Printf("admin: cleanup error: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "cleanup failed: " + err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"deleted_files":    fileCount,
		"deleted_versions": versionCount,
		"freed_bytes":      freedBytes,
	})
}

// handleCleanupPreview handles GET /api/admin/cleanup/preview.
func (s *Server) handleCleanupPreview(w http.ResponseWriter, r *http.Request) {
	beforeDateStr := r.URL.Query().Get("before_date")
	if beforeDateStr == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "before_date is required"})
		return
	}

	beforeDate, err := parseTimestamp(beforeDateStr)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "before_date must be RFC3339 or YYYY-MM-DD"})
		return
	}

	includeVersions := r.URL.Query().Get("include_versions") == "true"
	onlyDeleted := r.URL.Query().Get("only_deleted") == "true"

	fileCount, versionCount, totalBytes, err := s.db.PreviewCleanup(beforeDate, includeVersions, onlyDeleted)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "preview failed: " + err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"files_count":    fileCount,
		"versions_count": versionCount,
		"total_bytes":    totalBytes,
	})
}

// handleCleanupCalendar handles GET /api/admin/cleanup/calendar.
func (s *Server) handleCleanupCalendar(w http.ResponseWriter, r *http.Request) {
	months, err := s.db.GetDataCalendar()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not load calendar"})
		return
	}
	if months == nil {
		months = map[string][]int{}
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"months": months})
}

// handleAdminActivity handles GET /api/admin/activity.
func (s *Server) handleAdminActivity(w http.ResponseWriter, r *http.Request) {
	q := metadata.ActivityQuery{}

	q.UserID = r.URL.Query().Get("user_id")
	q.Action = r.URL.Query().Get("action")

	if limitStr := r.URL.Query().Get("limit"); limitStr != "" {
		if limit, err := strconv.Atoi(limitStr); err == nil {
			q.Limit = limit
		}
	}
	if offsetStr := r.URL.Query().Get("offset"); offsetStr != "" {
		if offset, err := strconv.Atoi(offsetStr); err == nil {
			q.Offset = offset
		}
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
