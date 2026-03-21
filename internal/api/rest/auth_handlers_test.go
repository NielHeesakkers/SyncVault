package rest

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
)

// createAdminAndToken creates an admin user in the DB and returns a valid access token for it.
func createAdminAndToken(t *testing.T, env *testEnv) (string, string) {
	t.Helper()
	hashed, err := auth.HashPassword("adminpass")
	if err != nil {
		t.Fatalf("HashPassword: %v", err)
	}
	admin, err := env.db.CreateUser("admin", "admin@example.com", hashed, "admin")
	if err != nil {
		t.Fatalf("CreateUser admin: %v", err)
	}
	token, _, err := env.jwt.GenerateTokens(admin.ID, admin.Username, admin.Role)
	if err != nil {
		t.Fatalf("GenerateTokens: %v", err)
	}
	return admin.ID, token
}

// TestRegister_AdminCreatesUser verifies that an admin can create a new user (POST /api/users → 201).
func TestRegister_AdminCreatesUser(t *testing.T) {
	env := newTestEnv(t)
	_, adminToken := createAdminAndToken(t, env)

	body := map[string]string{
		"username": "newuser",
		"email":    "newuser@example.com",
		"password": "secret123",
		"role":     "user",
	}
	b, _ := json.Marshal(body)

	req := httptest.NewRequest(http.MethodPost, "/api/users", bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+adminToken)
	req.Header.Set("Content-Type", "application/json")

	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201; body = %s", rr.Code, rr.Body.String())
	}

	var resp userInfo
	if err := json.NewDecoder(rr.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.Username != "newuser" {
		t.Errorf("Username = %q, want newuser", resp.Username)
	}
	if resp.Role != "user" {
		t.Errorf("Role = %q, want user", resp.Role)
	}
	if resp.ID == "" {
		t.Error("expected non-empty ID")
	}
}

// TestRegister_NonAdmin_Forbidden verifies that a regular user cannot create users (403).
func TestRegister_NonAdmin_Forbidden(t *testing.T) {
	env := newTestEnv(t)

	hashed, _ := auth.HashPassword("pass")
	regularUser, _ := env.db.CreateUser("regular", "regular@example.com", hashed, "user")
	token, _, _ := env.jwt.GenerateTokens(regularUser.ID, regularUser.Username, regularUser.Role)

	body := map[string]string{"username": "another", "email": "a@b.com", "password": "pw", "role": "user"}
	b, _ := json.Marshal(body)

	req := httptest.NewRequest(http.MethodPost, "/api/users", bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")

	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusForbidden {
		t.Errorf("status = %d, want 403", rr.Code)
	}
}

// TestLogin_Correct verifies that correct credentials return 200 with both tokens.
func TestLogin_Correct(t *testing.T) {
	env := newTestEnv(t)

	hashed, _ := auth.HashPassword("mypassword")
	env.db.CreateUser("loginuser", "login@example.com", hashed, "user")

	body := map[string]string{"username": "loginuser", "password": "mypassword"}
	b, _ := json.Marshal(body)

	req := httptest.NewRequest(http.MethodPost, "/api/auth/login", bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")

	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rr.Code, rr.Body.String())
	}

	var resp loginResponse
	if err := json.NewDecoder(rr.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.AccessToken == "" {
		t.Error("expected non-empty access_token")
	}
	if resp.RefreshToken == "" {
		t.Error("expected non-empty refresh_token")
	}
	if resp.User.Username != "loginuser" {
		t.Errorf("user.username = %q, want loginuser", resp.User.Username)
	}
}

// TestLogin_WrongPassword verifies that bad credentials return 401.
func TestLogin_WrongPassword(t *testing.T) {
	env := newTestEnv(t)

	hashed, _ := auth.HashPassword("correctpass")
	env.db.CreateUser("pwuser", "pw@example.com", hashed, "user")

	body := map[string]string{"username": "pwuser", "password": "wrongpass"}
	b, _ := json.Marshal(body)

	req := httptest.NewRequest(http.MethodPost, "/api/auth/login", bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")

	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401", rr.Code)
	}
}

// TestLogin_UnknownUser verifies that a non-existent user returns 401.
func TestLogin_UnknownUser(t *testing.T) {
	env := newTestEnv(t)

	body := map[string]string{"username": "nobody", "password": "anything"}
	b, _ := json.Marshal(body)

	req := httptest.NewRequest(http.MethodPost, "/api/auth/login", bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")

	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401", rr.Code)
	}
}

// TestRefresh_Valid verifies that a valid refresh token returns 200 with new tokens.
func TestRefresh_Valid(t *testing.T) {
	env := newTestEnv(t)

	hashed, _ := auth.HashPassword("pass")
	u, _ := env.db.CreateUser("refreshuser", "refresh@example.com", hashed, "user")
	_, refreshToken, _ := env.jwt.GenerateTokens(u.ID, u.Username, u.Role)

	body := map[string]string{"refresh_token": refreshToken}
	b, _ := json.Marshal(body)

	req := httptest.NewRequest(http.MethodPost, "/api/auth/refresh", bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")

	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rr.Code, rr.Body.String())
	}

	var resp map[string]string
	if err := json.NewDecoder(rr.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp["access_token"] == "" {
		t.Error("expected non-empty access_token")
	}
	if resp["refresh_token"] == "" {
		t.Error("expected non-empty refresh_token")
	}
}

// TestRefresh_Invalid verifies that a bad refresh token returns 401.
func TestRefresh_Invalid(t *testing.T) {
	env := newTestEnv(t)

	body := map[string]string{"refresh_token": "not.a.valid.token"}
	b, _ := json.Marshal(body)

	req := httptest.NewRequest(http.MethodPost, "/api/auth/refresh", bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")

	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401", rr.Code)
	}
}

// TestRegister_Duplicate verifies that creating a duplicate user returns 409.
func TestRegister_Duplicate(t *testing.T) {
	env := newTestEnv(t)
	_, adminToken := createAdminAndToken(t, env)

	body := map[string]string{
		"username": "dupuser",
		"email":    "dup@example.com",
		"password": "pass",
		"role":     "user",
	}
	b, _ := json.Marshal(body)

	// First creation.
	req1 := httptest.NewRequest(http.MethodPost, "/api/users", bytes.NewReader(b))
	req1.Header.Set("Authorization", "Bearer "+adminToken)
	req1.Header.Set("Content-Type", "application/json")
	rr1 := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr1, req1)
	if rr1.Code != http.StatusCreated {
		t.Fatalf("first creation: status = %d, want 201", rr1.Code)
	}

	// Duplicate creation.
	b2, _ := json.Marshal(body)
	req2 := httptest.NewRequest(http.MethodPost, "/api/users", bytes.NewReader(b2))
	req2.Header.Set("Authorization", "Bearer "+adminToken)
	req2.Header.Set("Content-Type", "application/json")
	rr2 := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr2, req2)
	if rr2.Code != http.StatusConflict {
		t.Errorf("duplicate creation: status = %d, want 409", rr2.Code)
	}
}
