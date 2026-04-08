package rest

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
	"github.com/NielHeesakkers/SyncVault/internal/email"
	"github.com/NielHeesakkers/SyncVault/internal/metadata"
	"github.com/NielHeesakkers/SyncVault/internal/storage"
	"github.com/go-chi/chi/v5"
	chimiddleware "github.com/go-chi/chi/v5/middleware"
)

// Server is the SyncVault REST API server.
type Server struct {
	db         *metadata.DB
	store      *storage.Store
	jwt        *auth.JWT
	email      *email.Service
	router     chi.Router
	uploadsDir string // base directory for chunked upload staging files
}

// NewServer creates a new Server and registers all routes.
// uploadsDir is the base directory for temporary chunked upload staging files (e.g. /data/uploads).
func NewServer(db *metadata.DB, store *storage.Store, jwt *auth.JWT, emailSvc *email.Service, uploadsDir string) *Server {
	s := &Server{
		db:         db,
		store:      store,
		jwt:        jwt,
		email:      emailSvc,
		router:     chi.NewRouter(),
		uploadsDir: uploadsDir,
	}
	// Clean up any expired upload sessions left from a previous run.
	_, _ = db.DeleteExpiredUploadSessions()
	s.setupRoutes()
	return s
}

// Router returns the underlying http.Handler.
func (s *Server) Router() http.Handler {
	return s.router
}

// setupRoutes registers all API routes.
func (s *Server) setupRoutes() {
	r := s.router

	r.Use(chimiddleware.Recoverer)
	r.Use(CORSMiddleware)
	r.Use(LoggingMiddleware)

	// Public routes.
	r.Get("/api/health", s.handleHealth)
	r.Get("/api/version", s.handleVersion)

	// Auth routes (public).
	r.Post("/api/auth/login", s.handleLogin)
	r.Post("/api/auth/refresh", s.handleRefresh)
	r.Post("/api/auth/forgot-password", s.handleForgotPassword)
	r.Post("/api/auth/reset-password", s.handleResetPassword)
	r.Get("/api/auth/auto-login", s.handleAutoLogin)

	// Public share routes (no auth required).
	r.Get("/s/{token}", s.handlePublicShare)
	r.Post("/s/{token}/download", s.handlePublicDownload)

	// Protected routes.
	r.Group(func(r chi.Router) {
		r.Use(auth.RequireAuth(s.jwt, s.db))

		r.Get("/api/me", s.handleMe)
		r.Put("/api/me/password", s.handleChangeMyPassword)

		// Admin-only user creation.
		r.With(auth.RequireAdmin).Post("/api/users", s.handleCreateUser)

		// File management.
		r.Get("/api/files", s.handleListFiles)
		r.Post("/api/files", s.handleCreateFile)
		r.Post("/api/files/upload", s.handleUploadFile)
		r.Get("/api/files/search", s.handleSearchFiles)
		// History routes must be registered before {id} routes so they are not caught as an id param.
		r.Get("/api/files/history", s.handleFilesAtTime)
		r.Get("/api/files/history/dates", s.handleChangeDates)
		r.Get("/api/files/history/download", s.handleDownloadFolderAtTime)
		r.Post("/api/files/history/restore", s.handleRestoreFolderAtTime)
		r.Get("/api/files/{id}", s.handleGetFile)
		r.Put("/api/files/{id}", s.handleUpdateFile)
		r.Put("/api/files/{id}/removed-locally", s.handleSetRemovedLocally)
		r.Delete("/api/files/{id}", s.handleDeleteFile)
		r.Post("/api/files/{id}/restore", s.handleRestoreFile)
		r.Get("/api/files/{id}/download", s.handleDownloadFile)
		// File locking.
		r.Post("/api/files/{id}/lock", s.handleLockFile)
		r.Delete("/api/files/{id}/lock", s.handleUnlockFile)
		r.Get("/api/files/{id}/lock", s.handleGetFileLock)

		r.Get("/api/trash", s.handleListTrash)
		r.Delete("/api/trash", s.handlePurgeTrash)
		r.Delete("/api/trash/{id}", s.handlePermanentlyDeleteFile)
		r.Get("/api/changes", s.handleListChanges)
		r.Get("/api/changes/v2", s.handleListChangesV2)
		r.Get("/api/activity", s.handleUserActivity)

		// Server-Sent Events for real-time push.
		r.Get("/api/events", s.handleSSE)

		// Chunked uploads (legacy).
		r.Post("/api/uploads/init", s.handleInitUpload)
		r.Put("/api/uploads/{id}/chunks/{n}", s.handleUploadChunk)
		r.Get("/api/uploads/{id}/status", s.handleUploadStatus)
		r.Post("/api/uploads/{id}/complete", s.handleCompleteUpload)

		// Direct block upload (preferred for large files).
		r.Put("/api/blocks/{hash}", s.handlePutBlock)
		r.Post("/api/blocks/check", s.handleCheckBlocks)
		r.Post("/api/files/from-blocks", s.handleCreateFileFromBlocks)

		// Delta sync.
		r.Get("/api/files/{id}/blocks", s.handleGetBlocks)
		r.Post("/api/files/{id}/delta", s.handleDeltaUpload)

		// Version management.
		r.Get("/api/files/{id}/versions", s.handleListVersions)
		r.Get("/api/files/{id}/versions/{versionNum}/download", s.handleDownloadVersion)
		r.Post("/api/files/{id}/versions/{versionNum}/restore", s.handleRestoreVersion)

		// Share management.
		r.Post("/api/files/{id}/shares", s.handleCreateShare)
		r.Get("/api/files/{id}/shares", s.handleListShares)
		r.Delete("/api/shares/{id}", s.handleDeleteShare)
		r.Get("/api/shares/mine", s.handleListMyShares)

		// Hash check and file tree (for sync clients).
		r.Post("/api/files/check-hashes", s.handleCheckHashes)
		r.Get("/api/files/tree", s.handleFileTree)
		r.Get("/api/files/{id}/tree", s.handleFileTree)

		// Known sync state (per user per device).
		r.Put("/api/sync-state/{deviceID}/{taskName}", s.handlePutSyncState)
		r.Get("/api/sync-state/{deviceID}/{taskName}", s.handleGetSyncState)
		r.Delete("/api/sync-state/{deviceID}/{taskName}", s.handleDeleteSyncState)

		// Sync task management.
		r.Get("/api/tasks", s.handleListTasks)
		r.Post("/api/tasks", s.handleCreateTask)
		r.Delete("/api/tasks/{id}", s.handleDeleteTask)
		r.Get("/api/tasks/{id}/retention", s.handleGetRetention)
		r.Put("/api/tasks/{id}/retention", s.handleSetRetention)

		// Notifications.
		r.Get("/api/notifications", s.handleListNotifications)
		r.Post("/api/notifications/{id}/accept", s.handleAcceptNotification)
		r.Post("/api/notifications/{id}/decline", s.handleDeclineNotification)
		r.Post("/api/notifications/read", s.handleMarkAllRead)

		// Team management.
		r.Get("/api/teams/mine", s.handleListMyTeams)
		r.Get("/api/teams/{id}/files", s.handleListTeamFiles)
		r.Get("/api/teams", s.handleListTeams)
		r.With(auth.RequireAdmin).Post("/api/teams", s.handleCreateTeam)
		r.With(auth.RequireAdmin).Put("/api/teams/{id}", s.handleUpdateTeam)
		r.With(auth.RequireAdmin).Post("/api/teams/{id}/transfer", s.handleTransferTeamFolder)
		r.With(auth.RequireAdmin).Delete("/api/teams/{id}", s.handleDeleteTeam)
		r.Get("/api/teams/{id}/members", s.handleListTeamMembers)
		r.Put("/api/teams/{id}/members/{userId}", s.handleSetTeamMember)
		r.Delete("/api/teams/{id}/members/{userId}", s.handleRemoveTeamMember)

		// Admin-only routes.
		r.Group(func(r chi.Router) {
			r.Use(auth.RequireAdmin)
			r.Get("/api/admin/users", s.handleAdminListUsers)
			r.Put("/api/admin/users/{id}", s.handleAdminUpdateUser)
			r.Post("/api/admin/users/{id}/transfer", s.handleAdminTransferUser)
			r.Delete("/api/admin/users/{id}", s.handleAdminDeleteUser)
			r.Post("/api/admin/users/{id}/reset-password", s.handleAdminResetPassword)
			r.Get("/api/admin/users/{id}/token", s.handleDownloadToken)
			r.Post("/api/admin/users/{id}/token/refresh", s.handleRefreshToken)
			r.Get("/api/admin/storage", s.handleAdminStorage)
			r.Get("/api/admin/storage/users", s.handleAdminStorageUsers)
			r.Get("/api/admin/storage/folders", s.handleAdminStorageFolders)
			r.Get("/api/admin/activity", s.handleAdminActivity)
			r.Get("/api/admin/settings", s.handleAdminGetSettings)
			r.Put("/api/admin/settings", s.handleAdminPutSettings)
			r.Post("/api/admin/settings/test-smtp", s.handleAdminTestSMTP)
			r.Post("/api/admin/settings/test-email", s.handleAdminTestEmail)
			r.Post("/api/admin/backups/upload", s.handleUploadRestore)
			r.Get("/api/admin/backups", s.handleListBackups)
			r.Post("/api/admin/backups", s.handleCreateBackup)
			r.Get("/api/admin/backups/{name}/download", s.handleDownloadBackup)
			r.Delete("/api/admin/backups/{name}", s.handleDeleteBackup)
			r.Post("/api/admin/backups/{name}/restore", s.handleRestoreBackup)
			r.Post("/api/admin/cleanup", s.handleAdminCleanup)
			r.Get("/api/admin/cleanup/preview", s.handleCleanupPreview)
			r.Get("/api/admin/cleanup/calendar", s.handleCleanupCalendar)
		})
	})

	// SPA catch-all — serve frontend for all non-API routes
	r.NotFound(ServeSPA().ServeHTTP)
}

const AppVersion = "2.5.35"

// handleHealth returns a simple health check response.
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "version": AppVersion})
}

// handleMe returns the current authenticated user's claims.
func (s *Server) handleMe(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	writeJSON(w, http.StatusOK, claims)
}

// writeJSON writes v as JSON with the given HTTP status code.
func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// readJSON decodes the JSON body of r into v. Limits body to 10 MB.
func readJSON(r *http.Request, v interface{}) error {
	r.Body = http.MaxBytesReader(nil, r.Body, 10<<20)
	return json.NewDecoder(r.Body).Decode(v)
}

// checkFileOwnership verifies the authenticated user owns the file (or is admin).
// Returns the file and true if OK, or writes an error response and returns false.
func (s *Server) checkFileOwnership(w http.ResponseWriter, r *http.Request, fileID string) (*metadata.File, bool) {
	claims := auth.GetClaims(r.Context())
	f, err := s.db.GetFileByID(fileID)
	if err != nil {
		if errors.Is(err, metadata.ErrFileNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "file not found"})
		} else {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get file"})
		}
		return nil, false
	}
	if f.OwnerID != claims.UserID && claims.Role != "admin" {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "access denied"})
		return nil, false
	}
	return f, true
}

// isHexHash returns true if s is a valid lowercase hex string of at least minLen characters.
func isHexHash(s string, minLen int) bool {
	if len(s) < minLen {
		return false
	}
	for _, c := range s {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

// parseTimestamp parses an ISO 8601 timestamp, accepting both RFC3339 and RFC3339Nano,
// as well as a date-only format (YYYY-MM-DD). Returns the parsed time or an error.
func parseTimestamp(s string) (time.Time, error) {
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339, "2006-01-02"} {
		if t, err := time.Parse(layout, s); err == nil {
			return t, nil
		}
	}
	return time.Time{}, fmt.Errorf("invalid timestamp %q: must be RFC3339 or YYYY-MM-DD", s)
}

// sanitizeFilename removes characters that could break Content-Disposition headers.
func sanitizeFilename(name string) string {
	var b []byte
	for _, c := range []byte(name) {
		if c == '"' || c == '\r' || c == '\n' || c == '\\' {
			continue
		}
		b = append(b, c)
	}
	return string(b)
}
