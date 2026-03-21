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
