package rest

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
)

// checkPw is a small wrapper so test files can call auth.CheckPassword without importing auth directly.
func checkPw(password, hash string) bool {
	return auth.CheckPassword(password, hash)
}

// TestAdminListUsers verifies GET /api/admin/users returns all users with storage stats.
func TestAdminListUsers(t *testing.T) {
	env := newTestEnv(t)
	_, adminToken := createAdminAndToken(t, env)

	// Create a couple of regular users.
	createUserAndToken(t, env, "adminlistuser1")
	createUserAndToken(t, env, "adminlistuser2")

	req := httptest.NewRequest(http.MethodGet, "/api/admin/users", nil)
	req.Header.Set("Authorization", "Bearer "+adminToken)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rr.Code, rr.Body.String())
	}

	var resp struct {
		Users []adminUserResponse `json:"users"`
	}
	if err := json.NewDecoder(rr.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	// 1 admin + 2 regular users = 3 total.
	if len(resp.Users) != 3 {
		t.Errorf("len(users) = %d, want 3", len(resp.Users))
	}
	// Each user should have a StorageUsed field (int64, could be 0).
	for _, u := range resp.Users {
		if u.ID == "" {
			t.Error("expected non-empty user ID")
		}
	}
}

// TestAdminListUsers_NonAdmin_Forbidden verifies 403 for regular users.
func TestAdminListUsers_NonAdmin_Forbidden(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "adminlistnonadmin")

	req := httptest.NewRequest(http.MethodGet, "/api/admin/users", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusForbidden {
		t.Errorf("status = %d, want 403", rr.Code)
	}
}

// TestAdminUpdateUser verifies PUT /api/admin/users/{id} updates user fields.
func TestAdminUpdateUser(t *testing.T) {
	env := newTestEnv(t)
	_, adminToken := createAdminAndToken(t, env)

	// Create a user to update.
	createUserAndToken(t, env, "updateme")
	u, _ := env.db.GetUserByUsername("updateme")

	newQuota := int64(1024 * 1024 * 100) // 100 MB
	body := map[string]interface{}{
		"email":       "updated@example.com",
		"role":        "admin",
		"quota_bytes": newQuota,
	}
	b, _ := json.Marshal(body)

	url := fmt.Sprintf("/api/admin/users/%s", u.ID)
	req := httptest.NewRequest(http.MethodPut, url, bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+adminToken)
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rr.Code, rr.Body.String())
	}

	var resp adminUserResponse
	json.NewDecoder(rr.Body).Decode(&resp)
	if resp.Email != "updated@example.com" {
		t.Errorf("Email = %q, want updated@example.com", resp.Email)
	}
	if resp.Role != "admin" {
		t.Errorf("Role = %q, want admin", resp.Role)
	}
	if resp.QuotaBytes != newQuota {
		t.Errorf("QuotaBytes = %d, want %d", resp.QuotaBytes, newQuota)
	}
}

// TestAdminDeleteUser verifies DELETE /api/admin/users/{id} removes a user.
func TestAdminDeleteUser(t *testing.T) {
	env := newTestEnv(t)
	_, adminToken := createAdminAndToken(t, env)

	createUserAndToken(t, env, "deleteadminuser")
	u, _ := env.db.GetUserByUsername("deleteadminuser")

	url := fmt.Sprintf("/api/admin/users/%s", u.ID)
	req := httptest.NewRequest(http.MethodDelete, url, nil)
	req.Header.Set("Authorization", "Bearer "+adminToken)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusNoContent {
		t.Errorf("status = %d, want 204; body = %s", rr.Code, rr.Body.String())
	}
}

// TestAdminResetPassword verifies POST /api/admin/users/{id}/reset-password.
func TestAdminResetPassword(t *testing.T) {
	env := newTestEnv(t)
	_, adminToken := createAdminAndToken(t, env)

	createUserAndToken(t, env, "pwresetuser")
	u, _ := env.db.GetUserByUsername("pwresetuser")

	body := map[string]string{"password": "newpass123"}
	b, _ := json.Marshal(body)

	url := fmt.Sprintf("/api/admin/users/%s/reset-password", u.ID)
	req := httptest.NewRequest(http.MethodPost, url, bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+adminToken)
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rr.Code, rr.Body.String())
	}

	// Verify the password was changed by checking the new password validates.
	updatedUser, err2 := env.db.GetUserByID(u.ID)
	if err2 != nil {
		t.Fatalf("GetUserByID after reset: %v", err2)
	}
	if !checkPw("newpass123", updatedUser.Password) {
		t.Error("new password does not validate against stored hash")
	}
}

// TestAdminStorage verifies GET /api/admin/storage returns totals.
func TestAdminStorage(t *testing.T) {
	env := newTestEnv(t)
	_, adminToken := createAdminAndToken(t, env)

	req := httptest.NewRequest(http.MethodGet, "/api/admin/storage", nil)
	req.Header.Set("Authorization", "Bearer "+adminToken)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rr.Code, rr.Body.String())
	}

	var resp storageOverviewResponse
	if err := json.NewDecoder(rr.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	// At least 1 user (the admin itself).
	if resp.TotalUsers < 1 {
		t.Errorf("TotalUsers = %d, want >= 1", resp.TotalUsers)
	}
}

// TestAdminActivity verifies GET /api/admin/activity returns (possibly empty) log.
func TestAdminActivity(t *testing.T) {
	env := newTestEnv(t)
	_, adminToken := createAdminAndToken(t, env)

	req := httptest.NewRequest(http.MethodGet, "/api/admin/activity", nil)
	req.Header.Set("Authorization", "Bearer "+adminToken)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rr.Code, rr.Body.String())
	}

	var resp map[string]interface{}
	if err := json.NewDecoder(rr.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if _, ok := resp["activity"]; !ok {
		t.Error("expected 'activity' key in response")
	}
}

// TestAdminStorageWithFiles verifies storage totals reflect uploaded files.
func TestAdminStorageWithFiles(t *testing.T) {
	env := newTestEnv(t)
	adminID, adminToken := createAdminAndToken(t, env)
	_ = adminID

	userToken := createUserAndToken(t, env, "storagefileuser")

	content := []byte("a file with known size content")
	uploadTestFile(t, env, userToken, "sizefile.txt", content)

	req := httptest.NewRequest(http.MethodGet, "/api/admin/storage", nil)
	req.Header.Set("Authorization", "Bearer "+adminToken)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	var resp storageOverviewResponse
	json.NewDecoder(rr.Body).Decode(&resp)

	if resp.Used < int64(len(content)) {
		t.Errorf("Used = %d, want at least %d", resp.Used, len(content))
	}
}
