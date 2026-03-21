package auth

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// okHandler is a simple handler that writes 200 OK and the role from claims.
var okHandler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
	claims := GetClaims(r.Context())
	w.WriteHeader(http.StatusOK)
	if claims != nil {
		_ = json.NewEncoder(w).Encode(map[string]string{"role": claims.Role, "username": claims.Username})
	}
})

func buildRequest(t *testing.T, token string) *http.Request {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	return req
}

func TestRequireAuth_ValidToken(t *testing.T) {
	j := newTestJWT()
	access, _, err := j.GenerateTokens("u1", "alice", "member")
	if err != nil {
		t.Fatalf("GenerateTokens: %v", err)
	}

	rr := httptest.NewRecorder()
	RequireAuth(j)(okHandler).ServeHTTP(rr, buildRequest(t, access))

	if rr.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", rr.Code)
	}

	// Claims should be accessible from the handler via context.
	var body map[string]string
	_ = json.NewDecoder(rr.Body).Decode(&body)
	if body["username"] != "alice" {
		t.Errorf("expected username 'alice' in context, got %q", body["username"])
	}
}

func TestRequireAuth_NoToken(t *testing.T) {
	j := newTestJWT()

	rr := httptest.NewRecorder()
	RequireAuth(j)(okHandler).ServeHTTP(rr, buildRequest(t, ""))

	if rr.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", rr.Code)
	}

	var body map[string]string
	_ = json.NewDecoder(rr.Body).Decode(&body)
	if body["error"] == "" {
		t.Error("expected JSON error body")
	}
}

func TestRequireAuth_InvalidToken(t *testing.T) {
	j := newTestJWT()

	rr := httptest.NewRecorder()
	RequireAuth(j)(okHandler).ServeHTTP(rr, buildRequest(t, "not.a.valid.jwt"))

	if rr.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", rr.Code)
	}

	var body map[string]string
	_ = json.NewDecoder(rr.Body).Decode(&body)
	if body["error"] == "" {
		t.Error("expected JSON error body")
	}
}

func TestRequireAdmin_AdminUser(t *testing.T) {
	j := newTestJWT()
	access, _, err := j.GenerateTokens("u2", "bob", "admin")
	if err != nil {
		t.Fatalf("GenerateTokens: %v", err)
	}

	rr := httptest.NewRecorder()
	handler := RequireAuth(j)(RequireAdmin(okHandler))
	handler.ServeHTTP(rr, buildRequest(t, access))

	if rr.Code != http.StatusOK {
		t.Errorf("expected 200 for admin user, got %d", rr.Code)
	}
}

func TestRequireAdmin_NormalUser(t *testing.T) {
	j := newTestJWT()
	access, _, err := j.GenerateTokens("u3", "carol", "member")
	if err != nil {
		t.Fatalf("GenerateTokens: %v", err)
	}

	rr := httptest.NewRecorder()
	handler := RequireAuth(j)(RequireAdmin(okHandler))
	handler.ServeHTTP(rr, buildRequest(t, access))

	if rr.Code != http.StatusForbidden {
		t.Errorf("expected 403 for non-admin user, got %d", rr.Code)
	}

	var body map[string]string
	_ = json.NewDecoder(rr.Body).Decode(&body)
	if body["error"] == "" {
		t.Error("expected JSON error body")
	}
}
