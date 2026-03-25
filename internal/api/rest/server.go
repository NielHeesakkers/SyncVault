package rest

import (
	"encoding/json"
	"net/http"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
	"github.com/NielHeesakkers/SyncVault/internal/email"
	"github.com/NielHeesakkers/SyncVault/internal/metadata"
	"github.com/NielHeesakkers/SyncVault/internal/storage"
	"github.com/go-chi/chi/v5"
	chimiddleware "github.com/go-chi/chi/v5/middleware"
)

// Server is the SyncVault REST API server.
type Server struct {
	db     *metadata.DB
	store  *storage.Store
	jwt    *auth.JWT
	email  *email.Service
	router chi.Router
}

// NewServer creates a new Server and registers all routes.
func NewServer(db *metadata.DB, store *storage.Store, jwt *auth.JWT, emailSvc *email.Service) *Server {
	s := &Server{
		db:     db,
		store:  store,
		jwt:    jwt,
		email:  emailSvc,
		router: chi.NewRouter(),
	}
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
		r.Use(auth.RequireAuth(s.jwt))

		r.Get("/api/me", s.handleMe)
		r.Put("/api/me/password", s.handleChangeMyPassword)

		// Admin-only user creation.
		r.With(auth.RequireAdmin).Post("/api/users", s.handleCreateUser)

		// File management.
		r.Get("/api/files", s.handleListFiles)
		r.Post("/api/files", s.handleCreateFile)
		r.Post("/api/files/upload", s.handleUploadFile)
		// History routes must be registered before {id} routes so they are not caught as an id param.
		r.Get("/api/files/history", s.handleFilesAtTime)
		r.Get("/api/files/history/dates", s.handleChangeDates)
		r.Get("/api/files/history/download", s.handleDownloadFolderAtTime)
		r.Post("/api/files/history/restore", s.handleRestoreFolderAtTime)
		r.Put("/api/files/{id}", s.handleUpdateFile)
		r.Delete("/api/files/{id}", s.handleDeleteFile)
		r.Post("/api/files/{id}/restore", s.handleRestoreFile)
		r.Get("/api/files/{id}/download", s.handleDownloadFile)
		r.Get("/api/trash", s.handleListTrash)
		r.Get("/api/changes", s.handleListChanges)

		// Version management.
		r.Get("/api/files/{id}/versions", s.handleListVersions)
		r.Get("/api/files/{id}/versions/{versionNum}/download", s.handleDownloadVersion)
		r.Post("/api/files/{id}/versions/{versionNum}/restore", s.handleRestoreVersion)

		// Share management.
		r.Post("/api/files/{id}/shares", s.handleCreateShare)
		r.Get("/api/files/{id}/shares", s.handleListShares)
		r.Delete("/api/shares/{id}", s.handleDeleteShare)
		r.Get("/api/shares/mine", s.handleListMyShares)

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
		})
	})

	// SPA catch-all — serve frontend for all non-API routes
	r.NotFound(ServeSPA().ServeHTTP)
}

const AppVersion = "2.1.9"

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

// readJSON decodes the JSON body of r into v.
func readJSON(r *http.Request, v interface{}) error {
	return json.NewDecoder(r.Body).Decode(v)
}
