package rest

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
	"github.com/NielHeesakkers/SyncVault/internal/metadata"
	"github.com/NielHeesakkers/SyncVault/internal/storage"
)

// testEnv holds a fully wired test server.
type testEnv struct {
	db     *metadata.DB
	store  *storage.Store
	jwt    *auth.JWT
	server *Server
}

// newTestEnv creates a fresh test environment with an in-memory-style DB, temp store, and JWT.
func newTestEnv(t *testing.T) *testEnv {
	t.Helper()
	dir := t.TempDir()

	db, err := metadata.Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("Open db: %v", err)
	}
	t.Cleanup(func() { db.Close() })

	store, err := storage.NewStore(filepath.Join(dir, "store"), 64*1024)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}

	jwtManager := auth.NewJWT("test-secret-for-testing")
	srv := NewServer(db, store, jwtManager)

	return &testEnv{
		db:     db,
		store:  store,
		jwt:    jwtManager,
		server: srv,
	}
}

func TestHealth(t *testing.T) {
	env := newTestEnv(t)

	req := httptest.NewRequest(http.MethodGet, "/api/health", nil)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("status = %d, want %d", rr.Code, http.StatusOK)
	}

	body := rr.Body.String()
	if body == "" {
		t.Error("expected non-empty body")
	}
}

func TestMeEndpoint_Unauthorized(t *testing.T) {
	env := newTestEnv(t)

	req := httptest.NewRequest(http.MethodGet, "/api/me", nil)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want %d (unauthorized)", rr.Code, http.StatusUnauthorized)
	}
}
