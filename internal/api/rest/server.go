package rest

import (
	"encoding/json"
	"net/http"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
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
	router chi.Router
}

// NewServer creates a new Server and registers all routes.
func NewServer(db *metadata.DB, store *storage.Store, jwt *auth.JWT) *Server {
	s := &Server{
		db:     db,
		store:  store,
		jwt:    jwt,
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

	// Auth routes (public).
	r.Post("/api/auth/login", s.handleLogin)
	r.Post("/api/auth/refresh", s.handleRefresh)

	// Public share routes (no auth required).
	r.Get("/s/{token}", s.handlePublicShare)
	r.Post("/s/{token}/download", s.handlePublicDownload)

	// Protected routes.
	r.Group(func(r chi.Router) {
		r.Use(auth.RequireAuth(s.jwt))

		r.Get("/api/me", s.handleMe)

		// Admin-only user creation.
		r.With(auth.RequireAdmin).Post("/api/users", s.handleCreateUser)

		// File management.
		r.Get("/api/files", s.handleListFiles)
		r.Post("/api/files", s.handleCreateFile)
		r.Post("/api/files/upload", s.handleUploadFile)
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

		// Team management.
		r.Get("/api/teams", s.handleListTeams)
		r.With(auth.RequireAdmin).Post("/api/teams", s.handleCreateTeam)
		r.With(auth.RequireAdmin).Delete("/api/teams/{id}", s.handleDeleteTeam)
		r.Get("/api/teams/{id}/members", s.handleListTeamMembers)
		r.Put("/api/teams/{id}/members/{userId}", s.handleSetTeamMember)
		r.Delete("/api/teams/{id}/members/{userId}", s.handleRemoveTeamMember)

		// Admin-only routes.
		r.Group(func(r chi.Router) {
			r.Use(auth.RequireAdmin)
			r.Get("/api/admin/users", s.handleAdminListUsers)
			r.Put("/api/admin/users/{id}", s.handleAdminUpdateUser)
			r.Delete("/api/admin/users/{id}", s.handleAdminDeleteUser)
			r.Post("/api/admin/users/{id}/reset-password", s.handleAdminResetPassword)
			r.Get("/api/admin/storage", s.handleAdminStorage)
			r.Get("/api/admin/activity", s.handleAdminActivity)
		})
	})

	// SPA catch-all — serve frontend for all non-API routes
	r.NotFound(ServeSPA().ServeHTTP)
}

// handleHealth returns a simple health check response.
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
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
