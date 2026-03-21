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
		r.Get("/api/files/{id}/download", s.handleDownloadFile)
	})
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
