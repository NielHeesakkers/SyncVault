package rest

import (
	"bytes"
	"encoding/json"
	"fmt"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"testing"
)

// uploadTestFile is a helper that uploads a file and returns the file ID and content hash.
func uploadTestFile(t *testing.T, env *testEnv, token string, filename string, content []byte) fileResponse {
	t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	fw, err := mw.CreateFormFile("file", filename)
	if err != nil {
		t.Fatalf("CreateFormFile: %v", err)
	}
	if _, err := fw.Write(content); err != nil {
		t.Fatalf("Write content: %v", err)
	}
	mw.Close()

	req := httptest.NewRequest(http.MethodPost, "/api/files/upload", &buf)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusCreated {
		t.Fatalf("upload: status = %d, want 201; body = %s", rr.Code, rr.Body.String())
	}
	var resp fileResponse
	if err := json.NewDecoder(rr.Body).Decode(&resp); err != nil {
		t.Fatalf("decode upload response: %v", err)
	}
	return resp
}

// TestListVersions verifies GET /api/files/{id}/versions returns version list.
func TestListVersions(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "versionlistuser")
	u, _ := env.db.GetUserByUsername("versionlistuser")

	uploaded := uploadTestFile(t, env, token, "vtest.txt", []byte("version 1 content"))

	// Add a second version manually.
	if _, err := env.db.CreateVersion(uploaded.ID, 2, "fakehash2", "", 100, u.ID); err != nil {
		t.Fatalf("CreateVersion: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, fmt.Sprintf("/api/files/%s/versions", uploaded.ID), nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rr.Code, rr.Body.String())
	}

	var resp struct {
		Versions []versionResponse `json:"versions"`
	}
	if err := json.NewDecoder(rr.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(resp.Versions) != 2 {
		t.Errorf("len(versions) = %d, want 2", len(resp.Versions))
	}
}

// TestListVersions_FileNotFound verifies 404 when file doesn't exist.
func TestListVersions_FileNotFound(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "vlistnotfound")

	req := httptest.NewRequest(http.MethodGet, "/api/files/nonexistent/versions", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404", rr.Code)
	}
}

// TestDownloadVersion verifies GET /api/files/{id}/versions/{versionNum}/download streams correct content.
func TestDownloadVersion(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "vdownloaduser")

	content := []byte("version 1 download content")
	uploaded := uploadTestFile(t, env, token, "vdl.txt", content)

	url := fmt.Sprintf("/api/files/%s/versions/1/download", uploaded.ID)
	req := httptest.NewRequest(http.MethodGet, url, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rr.Code, rr.Body.String())
	}
	if !bytes.Equal(rr.Body.Bytes(), content) {
		t.Errorf("body = %q, want %q", rr.Body.Bytes(), content)
	}
}

// TestRestoreVersion verifies POST /api/files/{id}/versions/{versionNum}/restore updates file content.
func TestRestoreVersion(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "vrestoreuser")
	u, _ := env.db.GetUserByUsername("vrestoreuser")

	// Upload initial version.
	originalContent := []byte("original content")
	uploaded := uploadTestFile(t, env, token, "vrestore.txt", originalContent)

	// Upload new content (v2 stored as a new entry in store).
	newContent := []byte("new content for v2")
	newHash, newSize, err := env.store.Put(bytes.NewReader(newContent))
	if err != nil {
		t.Fatalf("store.Put: %v", err)
	}

	// Create version 2.
	if _, err := env.db.CreateVersion(uploaded.ID, 2, newHash, "", newSize, u.ID); err != nil {
		t.Fatalf("CreateVersion: %v", err)
	}
	// Update file to v2.
	if err := env.db.UpdateFileContent(uploaded.ID, newHash, newSize); err != nil {
		t.Fatalf("UpdateFileContent: %v", err)
	}

	// Now restore to version 1.
	url := fmt.Sprintf("/api/files/%s/versions/1/restore", uploaded.ID)
	req := httptest.NewRequest(http.MethodPost, url, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rr.Code, rr.Body.String())
	}

	// Verify the file now points to v1 content by downloading it.
	dlURL := fmt.Sprintf("/api/files/%s/download", uploaded.ID)
	dlReq := httptest.NewRequest(http.MethodGet, dlURL, nil)
	dlReq.Header.Set("Authorization", "Bearer "+token)
	dlRR := httptest.NewRecorder()
	env.server.Router().ServeHTTP(dlRR, dlReq)

	if dlRR.Code != http.StatusOK {
		t.Fatalf("download after restore: status = %d", dlRR.Code)
	}
	if !bytes.Equal(dlRR.Body.Bytes(), originalContent) {
		t.Errorf("content after restore = %q, want %q", dlRR.Body.Bytes(), originalContent)
	}
}

// TestRestoreVersion_VersionNotFound verifies 404 for missing version.
func TestRestoreVersion_VersionNotFound(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "vrestorenotfound")

	uploaded := uploadTestFile(t, env, token, "vrnf.txt", []byte("content"))

	url := fmt.Sprintf("/api/files/%s/versions/99/restore", uploaded.ID)
	req := httptest.NewRequest(http.MethodPost, url, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404", rr.Code)
	}
}
