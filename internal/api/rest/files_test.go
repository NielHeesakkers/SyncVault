package rest

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
)

// createUserAndToken creates a regular user in the DB and returns a valid access token.
func createUserAndToken(t *testing.T, env *testEnv, username string) string {
	t.Helper()
	hashed, err := auth.HashPassword("testpass")
	if err != nil {
		t.Fatalf("HashPassword: %v", err)
	}
	u, err := env.db.CreateUser(username, username+"@example.com", hashed, "user")
	if err != nil {
		t.Fatalf("CreateUser %s: %v", username, err)
	}
	token, _, err := env.jwt.GenerateTokens(u.ID, u.Username, u.Role)
	if err != nil {
		t.Fatalf("GenerateTokens: %v", err)
	}
	return token
}

// TestCreateFolder verifies that POST /api/files creates a directory and returns 201.
func TestCreateFolder(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "folderuser")

	body := map[string]interface{}{
		"name":   "My Folder",
		"is_dir": true,
	}
	b, _ := json.Marshal(body)

	req := httptest.NewRequest(http.MethodPost, "/api/files", bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")

	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201; body = %s", rr.Code, rr.Body.String())
	}

	var resp fileResponse
	if err := json.NewDecoder(rr.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.Name != "My Folder" {
		t.Errorf("Name = %q, want My Folder", resp.Name)
	}
	if !resp.IsDir {
		t.Error("expected IsDir = true")
	}
	if resp.ID == "" {
		t.Error("expected non-empty ID")
	}
}

// TestListRootFiles verifies that GET /api/files lists files in the root.
func TestListRootFiles(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "listfileuser")

	// Create two items at root first.
	for _, name := range []string{"alpha.txt", "beta.txt"} {
		body := map[string]interface{}{"name": name, "is_dir": false}
		b, _ := json.Marshal(body)
		req := httptest.NewRequest(http.MethodPost, "/api/files", bytes.NewReader(b))
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Content-Type", "application/json")
		rr := httptest.NewRecorder()
		env.server.Router().ServeHTTP(rr, req)
		if rr.Code != http.StatusCreated {
			t.Fatalf("create %s: status %d", name, rr.Code)
		}
	}

	// List root files.
	req := httptest.NewRequest(http.MethodGet, "/api/files", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rr.Code, rr.Body.String())
	}

	var resp struct {
		Files []fileResponse `json:"files"`
	}
	if err := json.NewDecoder(rr.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(resp.Files) != 2 {
		t.Errorf("len(files) = %d, want 2", len(resp.Files))
	}
}

// TestUploadFile verifies multipart file upload returns 201 with the expected metadata.
func TestUploadFile(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "uploaduser")

	fileContent := []byte("Hello, SyncVault! This is a test file.")
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)

	fw, err := mw.CreateFormFile("file", "hello.txt")
	if err != nil {
		t.Fatalf("CreateFormFile: %v", err)
	}
	if _, err := fw.Write(fileContent); err != nil {
		t.Fatalf("Write file content: %v", err)
	}
	mw.Close()

	req := httptest.NewRequest(http.MethodPost, "/api/files/upload", &buf)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", mw.FormDataContentType())

	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201; body = %s", rr.Code, rr.Body.String())
	}

	var resp fileResponse
	if err := json.NewDecoder(rr.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.Name != "hello.txt" {
		t.Errorf("Name = %q, want hello.txt", resp.Name)
	}
	if resp.ID == "" {
		t.Error("expected non-empty ID")
	}
	if resp.ContentHash == "" {
		t.Error("expected non-empty ContentHash")
	}
	if resp.Size != int64(len(fileContent)) {
		t.Errorf("Size = %d, want %d", resp.Size, len(fileContent))
	}
}

// TestDownloadFile verifies that GET /api/files/{id}/download returns the original content.
func TestDownloadFile(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "downloaduser")

	fileContent := []byte("Download me please!")
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)

	fw, err := mw.CreateFormFile("file", "download.txt")
	if err != nil {
		t.Fatalf("CreateFormFile: %v", err)
	}
	fw.Write(fileContent)
	mw.Close()

	// Upload first.
	uploadReq := httptest.NewRequest(http.MethodPost, "/api/files/upload", &buf)
	uploadReq.Header.Set("Authorization", "Bearer "+token)
	uploadReq.Header.Set("Content-Type", mw.FormDataContentType())
	uploadRR := httptest.NewRecorder()
	env.server.Router().ServeHTTP(uploadRR, uploadReq)
	if uploadRR.Code != http.StatusCreated {
		t.Fatalf("upload status = %d, want 201; body = %s", uploadRR.Code, uploadRR.Body.String())
	}

	var uploadResp fileResponse
	if err := json.NewDecoder(uploadRR.Body).Decode(&uploadResp); err != nil {
		t.Fatalf("decode upload response: %v", err)
	}

	// Now download.
	dlURL := fmt.Sprintf("/api/files/%s/download", uploadResp.ID)
	dlReq := httptest.NewRequest(http.MethodGet, dlURL, nil)
	dlReq.Header.Set("Authorization", "Bearer "+token)
	dlRR := httptest.NewRecorder()
	env.server.Router().ServeHTTP(dlRR, dlReq)

	if dlRR.Code != http.StatusOK {
		t.Fatalf("download status = %d, want 200; body = %s", dlRR.Code, dlRR.Body.String())
	}

	got, err := io.ReadAll(dlRR.Body)
	if err != nil {
		t.Fatalf("read download body: %v", err)
	}
	if !bytes.Equal(got, fileContent) {
		t.Errorf("downloaded content = %q, want %q", got, fileContent)
	}
}

// TestDownloadFile_NotFound verifies that downloading a non-existent file returns 404.
func TestDownloadFile_NotFound(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "notfounduser")

	req := httptest.NewRequest(http.MethodGet, "/api/files/nonexistent-id/download", nil)
	req.Header.Set("Authorization", "Bearer "+token)

	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404", rr.Code)
	}
}

// TestListChanges_ReturnsModifiedAfterTimestamp verifies that only files modified after
// the since timestamp are returned, and that server_time is present in the response.
func TestListChanges_ReturnsModifiedAfterTimestamp(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "changesuser")

	// Create an "old" file via the API.
	createFile := func(name string) {
		body := map[string]interface{}{"name": name, "is_dir": false}
		b, _ := json.Marshal(body)
		req := httptest.NewRequest(http.MethodPost, "/api/files", bytes.NewReader(b))
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Content-Type", "application/json")
		rr := httptest.NewRecorder()
		env.server.Router().ServeHTTP(rr, req)
		if rr.Code != http.StatusCreated {
			t.Fatalf("create %s: status %d, body: %s", name, rr.Code, rr.Body.String())
		}
	}

	createFile("old.txt")

	// Use "now" as the cutoff after creating the old file.
	since := time.Now().UTC()

	// Small sleep to ensure the next file has a strictly later timestamp.
	time.Sleep(5 * time.Millisecond)

	createFile("recent.txt")

	sinceParam := since.Format(time.RFC3339Nano)
	req := httptest.NewRequest(http.MethodGet, "/api/changes?since="+sinceParam, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rr.Code, rr.Body.String())
	}

	var resp struct {
		Changes    []changeResponse `json:"changes"`
		ServerTime string           `json:"server_time"`
	}
	if err := json.NewDecoder(rr.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	if resp.ServerTime == "" {
		t.Error("expected server_time in response")
	}

	// Only "recent.txt" should appear.
	names := make(map[string]bool, len(resp.Changes))
	for _, c := range resp.Changes {
		names[c.Name] = true
	}
	if names["old.txt"] {
		t.Errorf("old.txt should NOT appear in changes (was created before since)")
	}
	if !names["recent.txt"] {
		t.Errorf("recent.txt should appear in changes")
	}
}

// TestListChanges_IncludesDeletions verifies that soft-deleted files appear in the change feed.
func TestListChanges_IncludesDeletions(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "deletionsuser")

	// Create the file that we will delete.
	body := map[string]interface{}{"name": "to_delete.txt", "is_dir": false}
	b, _ := json.Marshal(body)
	createReq := httptest.NewRequest(http.MethodPost, "/api/files", bytes.NewReader(b))
	createReq.Header.Set("Authorization", "Bearer "+token)
	createReq.Header.Set("Content-Type", "application/json")
	createRR := httptest.NewRecorder()
	env.server.Router().ServeHTTP(createRR, createReq)
	if createRR.Code != http.StatusCreated {
		t.Fatalf("create: status %d", createRR.Code)
	}
	var created fileResponse
	json.NewDecoder(createRR.Body).Decode(&created)

	// Record timestamp before deletion.
	since := time.Now().UTC()
	time.Sleep(5 * time.Millisecond)

	// Delete the file.
	delReq := httptest.NewRequest(http.MethodDelete, "/api/files/"+created.ID, nil)
	delReq.Header.Set("Authorization", "Bearer "+token)
	delRR := httptest.NewRecorder()
	env.server.Router().ServeHTTP(delRR, delReq)
	if delRR.Code != http.StatusNoContent {
		t.Fatalf("delete: status %d", delRR.Code)
	}

	// Poll the change feed.
	sinceParam := since.Format(time.RFC3339Nano)
	req := httptest.NewRequest(http.MethodGet, "/api/changes?since="+sinceParam, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rr.Code, rr.Body.String())
	}

	var resp struct {
		Changes []changeResponse `json:"changes"`
	}
	json.NewDecoder(rr.Body).Decode(&resp)

	found := false
	for _, c := range resp.Changes {
		if c.ID == created.ID {
			found = true
			if c.DeletedAt == nil {
				t.Errorf("expected deleted_at to be set for soft-deleted file in change feed")
			}
		}
	}
	if !found {
		t.Errorf("soft-deleted file %s should appear in change feed", created.ID)
	}
}

// TestListChanges_MissingSince verifies that omitting the since param returns 400.
func TestListChanges_MissingSince(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "missingsinceuser")

	req := httptest.NewRequest(http.MethodGet, "/api/changes", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", rr.Code)
	}
}

// TestListChanges_InvalidSince verifies that a malformed since param returns 400.
func TestListChanges_InvalidSince(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "invalidsinceuser")

	req := httptest.NewRequest(http.MethodGet, "/api/changes?since=not-a-timestamp", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", rr.Code)
	}
}

// TestListChanges_Unauthenticated verifies that the endpoint requires auth.
func TestListChanges_Unauthenticated(t *testing.T) {
	env := newTestEnv(t)

	req := httptest.NewRequest(http.MethodGet, "/api/changes?since=2026-01-01T00:00:00Z", nil)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401", rr.Code)
	}
}

// TestListChanges_FolderIDFilter verifies that the optional folder_id scopes results to that folder.
func TestListChanges_FolderIDFilter(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "folderfilteruser")

	// Create two folders.
	mkFolder := func(name string) string {
		body := map[string]interface{}{"name": name, "is_dir": true}
		b, _ := json.Marshal(body)
		req := httptest.NewRequest(http.MethodPost, "/api/files", bytes.NewReader(b))
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Content-Type", "application/json")
		rr := httptest.NewRecorder()
		env.server.Router().ServeHTTP(rr, req)
		var fr fileResponse
		json.NewDecoder(rr.Body).Decode(&fr)
		return fr.ID
	}

	folderA := mkFolder("FolderA")
	folderB := mkFolder("FolderB")

	since := time.Now().UTC()
	time.Sleep(5 * time.Millisecond)

	// Create one file in each folder after the cutoff.
	mkFile := func(name, parentID string) {
		body := map[string]interface{}{"name": name, "is_dir": false, "parent_id": parentID}
		b, _ := json.Marshal(body)
		req := httptest.NewRequest(http.MethodPost, "/api/files", bytes.NewReader(b))
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Content-Type", "application/json")
		rr := httptest.NewRecorder()
		env.server.Router().ServeHTTP(rr, req)
		if rr.Code != http.StatusCreated {
			t.Fatalf("mkFile %s: status %d, body: %s", name, rr.Code, rr.Body.String())
		}
	}

	mkFile("in_a.txt", folderA)
	mkFile("in_b.txt", folderB)

	sinceParam := since.Format(time.RFC3339Nano)
	url := fmt.Sprintf("/api/changes?since=%s&folder_id=%s", sinceParam, folderA)
	req := httptest.NewRequest(http.MethodGet, url, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rr.Code, rr.Body.String())
	}

	var resp struct {
		Changes []changeResponse `json:"changes"`
	}
	json.NewDecoder(rr.Body).Decode(&resp)

	for _, c := range resp.Changes {
		if c.Name == "in_b.txt" {
			t.Errorf("in_b.txt (in FolderB) should NOT appear when filtering by FolderA")
		}
	}

	found := false
	for _, c := range resp.Changes {
		if c.Name == "in_a.txt" {
			found = true
		}
	}
	if !found {
		t.Errorf("in_a.txt (in FolderA) should appear when filtering by FolderA")
	}
}
