package integration_test

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/NielHeesakkers/SyncVault/internal/api/rest"
	"github.com/NielHeesakkers/SyncVault/internal/auth"
	"github.com/NielHeesakkers/SyncVault/internal/metadata"
	"github.com/NielHeesakkers/SyncVault/internal/storage"
)

// setupServer creates a full test server backed by temp-dir DB and storage.
// It returns the httptest.Server, the metadata DB, and a cleanup function.
func setupServer(t *testing.T) (*httptest.Server, *metadata.DB) {
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

	jwtManager := auth.NewJWT("integration-test-secret")
	srv := rest.NewServer(db, store, jwtManager, nil)

	ts := httptest.NewServer(srv.Router())
	t.Cleanup(ts.Close)

	return ts, db
}

// login posts to /api/auth/login and returns the access token.
func login(t *testing.T, ts *httptest.Server, username, password string) string {
	t.Helper()
	body := map[string]string{"username": username, "password": password}
	b, _ := json.Marshal(body)

	resp, err := ts.Client().Post(ts.URL+"/api/auth/login", "application/json", bytes.NewReader(b))
	if err != nil {
		t.Fatalf("login POST: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		raw, _ := io.ReadAll(resp.Body)
		t.Fatalf("login status = %d, want 200; body = %s", resp.StatusCode, raw)
	}

	var result struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		t.Fatalf("decode login response: %v", err)
	}
	return result.AccessToken
}

// authRequest creates an authenticated HTTP request.
func authRequest(method, url, contentType string, body io.Reader, token string) *http.Request {
	req, _ := http.NewRequest(method, url, body)
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	return req
}

func TestFullWorkflow(t *testing.T) {
	ts, db := setupServer(t)
	client := ts.Client()

	// --- Setup: create admin user ---
	adminHash, err := auth.HashPassword("admin")
	if err != nil {
		t.Fatalf("HashPassword: %v", err)
	}
	if _, err := db.CreateUser("admin", "admin@localhost", adminHash, "admin"); err != nil {
		t.Fatalf("CreateUser admin: %v", err)
	}

	// --- Step 1: Login as admin ---
	adminToken := login(t, ts, "admin", "admin")
	if adminToken == "" {
		t.Fatal("expected non-empty admin token")
	}

	// --- Step 2: Create user "alice" via POST /api/users (admin only) ---
	createUserBody := map[string]string{
		"username": "alice",
		"email":    "alice@example.com",
		"password": "alicepass",
		"role":     "user",
	}
	cuBody, _ := json.Marshal(createUserBody)
	cuReq := authRequest(http.MethodPost, ts.URL+"/api/users", "application/json", bytes.NewReader(cuBody), adminToken)
	cuResp, err := client.Do(cuReq)
	if err != nil {
		t.Fatalf("create user POST: %v", err)
	}
	defer cuResp.Body.Close()
	if cuResp.StatusCode != http.StatusCreated {
		raw, _ := io.ReadAll(cuResp.Body)
		t.Fatalf("create user status = %d, want 201; body = %s", cuResp.StatusCode, raw)
	}

	var createdUser struct {
		ID       string `json:"id"`
		Username string `json:"username"`
		Role     string `json:"role"`
	}
	if err := json.NewDecoder(cuResp.Body).Decode(&createdUser); err != nil {
		t.Fatalf("decode create user response: %v", err)
	}
	if createdUser.Username != "alice" {
		t.Errorf("username = %q, want alice", createdUser.Username)
	}

	// --- Step 3: Login as alice ---
	aliceToken := login(t, ts, "alice", "alicepass")
	if aliceToken == "" {
		t.Fatal("expected non-empty alice token")
	}

	// --- Step 4: Create folder "MyDocs" ---
	folderBody := map[string]interface{}{"name": "MyDocs", "is_dir": true}
	fb, _ := json.Marshal(folderBody)
	folderReq := authRequest(http.MethodPost, ts.URL+"/api/files", "application/json", bytes.NewReader(fb), aliceToken)
	folderResp, err := client.Do(folderReq)
	if err != nil {
		t.Fatalf("create folder POST: %v", err)
	}
	defer folderResp.Body.Close()
	if folderResp.StatusCode != http.StatusCreated {
		raw, _ := io.ReadAll(folderResp.Body)
		t.Fatalf("create folder status = %d, want 201; body = %s", folderResp.StatusCode, raw)
	}

	var folder struct {
		ID    string `json:"id"`
		Name  string `json:"name"`
		IsDir bool   `json:"is_dir"`
	}
	if err := json.NewDecoder(folderResp.Body).Decode(&folder); err != nil {
		t.Fatalf("decode folder response: %v", err)
	}
	if folder.Name != "MyDocs" {
		t.Errorf("folder name = %q, want MyDocs", folder.Name)
	}
	if !folder.IsDir {
		t.Error("expected is_dir = true")
	}

	// --- Step 5: Upload file "hello.txt" ---
	fileContent := []byte("Hello SyncVault!")
	var uploadBuf bytes.Buffer
	mw := multipart.NewWriter(&uploadBuf)
	fw, err := mw.CreateFormFile("file", "hello.txt")
	if err != nil {
		t.Fatalf("CreateFormFile: %v", err)
	}
	if _, err := fw.Write(fileContent); err != nil {
		t.Fatalf("write file content: %v", err)
	}
	mw.Close()

	uploadReq := authRequest(http.MethodPost, ts.URL+"/api/files/upload", mw.FormDataContentType(), &uploadBuf, aliceToken)
	uploadResp, err := client.Do(uploadReq)
	if err != nil {
		t.Fatalf("upload POST: %v", err)
	}
	defer uploadResp.Body.Close()
	if uploadResp.StatusCode != http.StatusCreated {
		raw, _ := io.ReadAll(uploadResp.Body)
		t.Fatalf("upload status = %d, want 201; body = %s", uploadResp.StatusCode, raw)
	}

	var uploadedFile struct {
		ID          string `json:"id"`
		Name        string `json:"name"`
		Size        int64  `json:"size"`
		ContentHash string `json:"content_hash"`
	}
	if err := json.NewDecoder(uploadResp.Body).Decode(&uploadedFile); err != nil {
		t.Fatalf("decode upload response: %v", err)
	}
	if uploadedFile.Name != "hello.txt" {
		t.Errorf("uploaded file name = %q, want hello.txt", uploadedFile.Name)
	}
	if uploadedFile.Size != int64(len(fileContent)) {
		t.Errorf("size = %d, want %d", uploadedFile.Size, len(fileContent))
	}
	if uploadedFile.ContentHash == "" {
		t.Error("expected non-empty content_hash")
	}
	if uploadedFile.ID == "" {
		t.Fatal("expected non-empty file ID")
	}

	// --- Step 6: Download file → verify content matches ---
	dlURL := fmt.Sprintf("%s/api/files/%s/download", ts.URL, uploadedFile.ID)
	dlReq := authRequest(http.MethodGet, dlURL, "", nil, aliceToken)
	dlResp, err := client.Do(dlReq)
	if err != nil {
		t.Fatalf("download GET: %v", err)
	}
	defer dlResp.Body.Close()
	if dlResp.StatusCode != http.StatusOK {
		raw, _ := io.ReadAll(dlResp.Body)
		t.Fatalf("download status = %d, want 200; body = %s", dlResp.StatusCode, raw)
	}

	downloaded, err := io.ReadAll(dlResp.Body)
	if err != nil {
		t.Fatalf("read download body: %v", err)
	}
	if !bytes.Equal(downloaded, fileContent) {
		t.Errorf("downloaded content = %q, want %q", downloaded, fileContent)
	}

	// --- Step 7: List files → verify items present ---
	listReq := authRequest(http.MethodGet, ts.URL+"/api/files", "", nil, aliceToken)
	listResp, err := client.Do(listReq)
	if err != nil {
		t.Fatalf("list files GET: %v", err)
	}
	defer listResp.Body.Close()
	if listResp.StatusCode != http.StatusOK {
		raw, _ := io.ReadAll(listResp.Body)
		t.Fatalf("list files status = %d, want 200; body = %s", listResp.StatusCode, raw)
	}

	var listResult struct {
		Files []struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"files"`
	}
	if err := json.NewDecoder(listResp.Body).Decode(&listResult); err != nil {
		t.Fatalf("decode list response: %v", err)
	}
	if len(listResult.Files) < 2 {
		t.Errorf("len(files) = %d, want at least 2 (folder + uploaded file)", len(listResult.Files))
	}

	// Verify both MyDocs and hello.txt appear.
	found := map[string]bool{}
	for _, f := range listResult.Files {
		found[f.Name] = true
	}
	if !found["MyDocs"] {
		t.Error("expected MyDocs in file list")
	}
	if !found["hello.txt"] {
		t.Error("expected hello.txt in file list")
	}

	// --- Step 8: Health check ---
	healthResp, err := client.Get(ts.URL + "/api/health")
	if err != nil {
		t.Fatalf("health GET: %v", err)
	}
	defer healthResp.Body.Close()
	if healthResp.StatusCode != http.StatusOK {
		raw, _ := io.ReadAll(healthResp.Body)
		t.Fatalf("health status = %d, want 200; body = %s", healthResp.StatusCode, raw)
	}
}
