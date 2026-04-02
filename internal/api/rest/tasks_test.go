package rest

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
	"github.com/NielHeesakkers/SyncVault/internal/metadata"
)

// createUserWithRootFolder creates a user and their root folder, returning the user and token.
func createUserWithRootFolder(t *testing.T, env *testEnv, username string) (*metadata.User, string) {
	t.Helper()
	hashed, err := auth.HashPassword("testpass")
	if err != nil {
		t.Fatalf("HashPassword: %v", err)
	}
	u, err := env.db.CreateUser(username, username+"@example.com", hashed, "user")
	if err != nil {
		t.Fatalf("CreateUser %s: %v", username, err)
	}
	if _, err := env.db.CreateFile("", u.ID, u.Username, true, 0, "", ""); err != nil {
		t.Fatalf("CreateFile root folder for %s: %v", username, err)
	}
	token, _, err := env.jwt.GenerateTokens(u.ID, u.Username, u.Role)
	if err != nil {
		t.Fatalf("GenerateTokens: %v", err)
	}
	return u, token
}

// TestHandleCreateUser_AutoCreatesRootFolder verifies that POST /api/users auto-creates a root folder.
func TestHandleCreateUser_AutoCreatesRootFolder(t *testing.T) {
	env := newTestEnv(t)
	_, adminToken := createAdminAndToken(t, env)

	body := map[string]string{
		"username": "newfolderuser",
		"email":    "newfolderuser@example.com",
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

	// Check that a root folder was created for the new user.
	rootFolder, err := env.db.GetUserRootFolder(resp.ID)
	if err != nil {
		t.Fatalf("GetUserRootFolder: expected root folder to exist after user creation, got error: %v", err)
	}
	if rootFolder.Name != "newfolderuser" {
		t.Errorf("root folder name = %q, want newfolderuser", rootFolder.Name)
	}
	if !rootFolder.IsDir {
		t.Error("expected root folder to be a directory")
	}
	if rootFolder.ParentID.Valid {
		t.Error("expected root folder to have no parent")
	}
}

// TestHandleCreateTask_Sync verifies that POST /api/tasks creates a sync task and its subfolder.
func TestHandleCreateTask_Sync(t *testing.T) {
	env := newTestEnv(t)
	_, token := createUserWithRootFolder(t, env, "synctaskuser")

	body := map[string]string{
		"name":       "Documents",
		"type":       "sync",
		"local_path": "/Users/synctaskuser/Documents",
	}
	b, _ := json.Marshal(body)

	req := httptest.NewRequest(http.MethodPost, "/api/tasks", bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")

	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201; body = %s", rr.Code, rr.Body.String())
	}

	var resp taskResponse
	if err := json.NewDecoder(rr.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.ID == "" {
		t.Error("expected non-empty task ID")
	}
	if resp.Name != "Documents" {
		t.Errorf("Name = %q, want Documents", resp.Name)
	}
	if resp.Type != "sync" {
		t.Errorf("Type = %q, want sync", resp.Type)
	}
	if resp.FolderName != "Sync-Documents" {
		t.Errorf("FolderName = %q, want Sync-Documents", resp.FolderName)
	}
	if resp.FolderID == "" {
		t.Error("expected non-empty folder ID")
	}
}

// TestHandleCreateTask_Backup verifies the "Backup-{Name}" folder naming.
func TestHandleCreateTask_Backup(t *testing.T) {
	env := newTestEnv(t)
	_, token := createUserWithRootFolder(t, env, "backuptaskuser")

	body := map[string]string{
		"name": "Desktop",
		"type": "backup",
	}
	b, _ := json.Marshal(body)

	req := httptest.NewRequest(http.MethodPost, "/api/tasks", bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")

	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201; body = %s", rr.Code, rr.Body.String())
	}

	var resp taskResponse
	json.NewDecoder(rr.Body).Decode(&resp)
	if resp.FolderName != "Backup-Desktop" {
		t.Errorf("FolderName = %q, want Backup-Desktop", resp.FolderName)
	}
}

// TestHandleCreateTask_OnDemand verifies the "OnDemand" folder naming.
func TestHandleCreateTask_OnDemand(t *testing.T) {
	env := newTestEnv(t)
	_, token := createUserWithRootFolder(t, env, "ondemandtaskuser")

	body := map[string]string{
		"type": "ondemand",
	}
	b, _ := json.Marshal(body)

	req := httptest.NewRequest(http.MethodPost, "/api/tasks", bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")

	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201; body = %s", rr.Code, rr.Body.String())
	}

	var resp taskResponse
	json.NewDecoder(rr.Body).Decode(&resp)
	if resp.FolderName != "OnDemand" {
		t.Errorf("FolderName = %q, want OnDemand", resp.FolderName)
	}
	if resp.Type != "ondemand" {
		t.Errorf("Type = %q, want ondemand", resp.Type)
	}
}

// TestHandleCreateTask_OnDemand_ReplacesExisting verifies that a second ondemand task replaces the first.
func TestHandleCreateTask_OnDemand_ReplacesExisting(t *testing.T) {
	env := newTestEnv(t)
	_, token := createUserWithRootFolder(t, env, "ondemandlimituser")

	makeReq := func() *httptest.ResponseRecorder {
		body := map[string]string{"type": "ondemand"}
		b, _ := json.Marshal(body)
		req := httptest.NewRequest(http.MethodPost, "/api/tasks", bytes.NewReader(b))
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Content-Type", "application/json")
		rr := httptest.NewRecorder()
		env.server.Router().ServeHTTP(rr, req)
		return rr
	}

	rr1 := makeReq()
	if rr1.Code != http.StatusCreated {
		t.Fatalf("first ondemand task: status = %d, want 201; body = %s", rr1.Code, rr1.Body.String())
	}
	var resp1 taskResponse
	json.NewDecoder(rr1.Body).Decode(&resp1)

	rr2 := makeReq()
	if rr2.Code != http.StatusCreated {
		t.Errorf("second ondemand task (replace): status = %d, want 201; body = %s", rr2.Code, rr2.Body.String())
	}
	var resp2 taskResponse
	json.NewDecoder(rr2.Body).Decode(&resp2)

	if resp2.ID == resp1.ID {
		t.Errorf("second task should have a new ID, got same: %s", resp2.ID)
	}
}

// TestHandleListTasks verifies that GET /api/tasks returns all tasks for the user.
func TestHandleListTasks(t *testing.T) {
	env := newTestEnv(t)
	_, token := createUserWithRootFolder(t, env, "listtaskuser")

	createTask := func(name, taskType string) {
		body := map[string]string{"name": name, "type": taskType}
		b, _ := json.Marshal(body)
		req := httptest.NewRequest(http.MethodPost, "/api/tasks", bytes.NewReader(b))
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Content-Type", "application/json")
		rr := httptest.NewRecorder()
		env.server.Router().ServeHTTP(rr, req)
		if rr.Code != http.StatusCreated {
			t.Fatalf("createTask %s/%s: status = %d; body = %s", name, taskType, rr.Code, rr.Body.String())
		}
	}

	createTask("Docs", "sync")
	createTask("Desktop", "backup")

	req := httptest.NewRequest(http.MethodGet, "/api/tasks", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("list tasks: status = %d, want 200; body = %s", rr.Code, rr.Body.String())
	}

	var resp []taskResponse
	if err := json.NewDecoder(rr.Body).Decode(&resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(resp) != 2 {
		t.Errorf("len(tasks) = %d, want 2", len(resp))
	}
}

// TestHandleDeleteTask verifies that DELETE /api/tasks/{id} removes the task.
func TestHandleDeleteTask(t *testing.T) {
	env := newTestEnv(t)
	_, token := createUserWithRootFolder(t, env, "deltaskrestuser")

	// Create a task.
	body := map[string]string{"name": "ToDelete", "type": "sync"}
	b, _ := json.Marshal(body)
	req := httptest.NewRequest(http.MethodPost, "/api/tasks", bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)
	if rr.Code != http.StatusCreated {
		t.Fatalf("create task: status = %d; body = %s", rr.Code, rr.Body.String())
	}
	var created taskResponse
	json.NewDecoder(rr.Body).Decode(&created)

	// Delete the task.
	req2 := httptest.NewRequest(http.MethodDelete, "/api/tasks/"+created.ID, nil)
	req2.Header.Set("Authorization", "Bearer "+token)
	rr2 := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr2, req2)

	if rr2.Code != http.StatusOK {
		t.Fatalf("delete task: status = %d, want 200; body = %s", rr2.Code, rr2.Body.String())
	}

	// List tasks — should be empty.
	req3 := httptest.NewRequest(http.MethodGet, "/api/tasks", nil)
	req3.Header.Set("Authorization", "Bearer "+token)
	rr3 := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr3, req3)
	var listed []taskResponse
	json.NewDecoder(rr3.Body).Decode(&listed)
	if len(listed) != 0 {
		t.Errorf("expected 0 tasks after deletion, got %d", len(listed))
	}
}

// TestHandleDeleteTask_OtherUserForbidden verifies that a user cannot delete another user's task.
func TestHandleDeleteTask_OtherUserForbidden(t *testing.T) {
	env := newTestEnv(t)
	_, tokenA := createUserWithRootFolder(t, env, "owneruser")
	_, tokenB := createUserWithRootFolder(t, env, "otheruser")

	// User A creates a task.
	body := map[string]string{"name": "Private", "type": "sync"}
	b, _ := json.Marshal(body)
	req := httptest.NewRequest(http.MethodPost, "/api/tasks", bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+tokenA)
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)
	if rr.Code != http.StatusCreated {
		t.Fatalf("create task: status = %d; body = %s", rr.Code, rr.Body.String())
	}
	var created taskResponse
	json.NewDecoder(rr.Body).Decode(&created)

	// User B tries to delete it.
	req2 := httptest.NewRequest(http.MethodDelete, "/api/tasks/"+created.ID, nil)
	req2.Header.Set("Authorization", "Bearer "+tokenB)
	rr2 := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr2, req2)

	if rr2.Code != http.StatusForbidden {
		t.Errorf("expected 403, got %d", rr2.Code)
	}
}

// TestHandleCreateTask_MissingRootFolder verifies 409 when no root folder exists.
func TestHandleCreateTask_MissingRootFolder(t *testing.T) {
	env := newTestEnv(t)
	// Create a user but deliberately skip creating the root folder.
	hashed, _ := auth.HashPassword("pass")
	u, _ := env.db.CreateUser("norootuser", "noroot@example.com", hashed, "user")
	token, _, _ := env.jwt.GenerateTokens(u.ID, u.Username, u.Role)

	body := map[string]string{"name": "Docs", "type": "sync"}
	b, _ := json.Marshal(body)
	req := httptest.NewRequest(http.MethodPost, "/api/tasks", bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusConflict {
		t.Errorf("expected 409 when root folder is missing, got %d; body = %s", rr.Code, rr.Body.String())
	}
}

// TestHandleCreateTask_InvalidType verifies 400 for an unknown task type.
func TestHandleCreateTask_InvalidType(t *testing.T) {
	env := newTestEnv(t)
	_, token := createUserWithRootFolder(t, env, "invalidtypeuser")

	body := map[string]string{"name": "X", "type": "bogus"}
	b, _ := json.Marshal(body)
	req := httptest.NewRequest(http.MethodPost, "/api/tasks", bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusBadRequest {
		t.Errorf("expected 400 for bogus type, got %d", rr.Code)
	}
}
