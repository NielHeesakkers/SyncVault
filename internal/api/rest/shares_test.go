package rest

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestCreateShare verifies POST /api/files/{id}/shares creates a share link.
func TestCreateShare(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "sharecreatuser")

	uploaded := uploadTestFile(t, env, token, "sharefile.txt", []byte("shareable content"))

	body := map[string]interface{}{
		"max_downloads": 5,
	}
	b, _ := json.Marshal(body)
	url := fmt.Sprintf("/api/files/%s/shares", uploaded.ID)
	req := httptest.NewRequest(http.MethodPost, url, bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201; body = %s", rr.Code, rr.Body.String())
	}

	var resp shareLinkResponse
	if err := json.NewDecoder(rr.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if resp.Token == "" {
		t.Error("expected non-empty token")
	}
	if resp.MaxDownloads != 5 {
		t.Errorf("MaxDownloads = %d, want 5", resp.MaxDownloads)
	}
	if resp.HasPassword {
		t.Error("expected HasPassword = false")
	}
}

// TestCreateShare_WithPassword verifies that a share with password has HasPassword=true.
func TestCreateShare_WithPassword(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "sharepwuser")

	uploaded := uploadTestFile(t, env, token, "pwshare.txt", []byte("protected content"))

	body := map[string]interface{}{
		"password": "secret123",
	}
	b, _ := json.Marshal(body)
	url := fmt.Sprintf("/api/files/%s/shares", uploaded.ID)
	req := httptest.NewRequest(http.MethodPost, url, bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201; body = %s", rr.Code, rr.Body.String())
	}

	var resp shareLinkResponse
	if err := json.NewDecoder(rr.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if !resp.HasPassword {
		t.Error("expected HasPassword = true")
	}
}

// TestListShares verifies GET /api/files/{id}/shares returns the list.
func TestListShares(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "sharelistuser")

	uploaded := uploadTestFile(t, env, token, "listshare.txt", []byte("list content"))

	// Create two share links.
	for i := 0; i < 2; i++ {
		b, _ := json.Marshal(map[string]interface{}{})
		url := fmt.Sprintf("/api/files/%s/shares", uploaded.ID)
		req := httptest.NewRequest(http.MethodPost, url, bytes.NewReader(b))
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Content-Type", "application/json")
		rr := httptest.NewRecorder()
		env.server.Router().ServeHTTP(rr, req)
		if rr.Code != http.StatusCreated {
			t.Fatalf("create share %d: status = %d", i, rr.Code)
		}
	}

	url := fmt.Sprintf("/api/files/%s/shares", uploaded.ID)
	req := httptest.NewRequest(http.MethodGet, url, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rr.Code, rr.Body.String())
	}

	var resp struct {
		Shares []shareLinkResponse `json:"shares"`
	}
	if err := json.NewDecoder(rr.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(resp.Shares) != 2 {
		t.Errorf("len(shares) = %d, want 2", len(resp.Shares))
	}
}

// TestDeleteShare verifies DELETE /api/shares/{id} removes a share link.
func TestDeleteShare(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "sharedeluser")

	uploaded := uploadTestFile(t, env, token, "delshare.txt", []byte("del content"))

	// Create a share link.
	b, _ := json.Marshal(map[string]interface{}{})
	url := fmt.Sprintf("/api/files/%s/shares", uploaded.ID)
	req := httptest.NewRequest(http.MethodPost, url, bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)
	if rr.Code != http.StatusCreated {
		t.Fatalf("create share: status = %d", rr.Code)
	}
	var shareResp shareLinkResponse
	json.NewDecoder(rr.Body).Decode(&shareResp)

	// Delete it.
	delURL := fmt.Sprintf("/api/shares/%s", shareResp.ID)
	delReq := httptest.NewRequest(http.MethodDelete, delURL, nil)
	delReq.Header.Set("Authorization", "Bearer "+token)
	delRR := httptest.NewRecorder()
	env.server.Router().ServeHTTP(delRR, delReq)

	if delRR.Code != http.StatusNoContent {
		t.Errorf("status = %d, want 204", delRR.Code)
	}
}

// TestListMyShares verifies GET /api/shares/mine returns the user's shares.
func TestListMyShares(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "myshareuser")

	uploaded := uploadTestFile(t, env, token, "myshare.txt", []byte("my content"))

	b, _ := json.Marshal(map[string]interface{}{})
	url := fmt.Sprintf("/api/files/%s/shares", uploaded.ID)
	req := httptest.NewRequest(http.MethodPost, url, bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)
	if rr.Code != http.StatusCreated {
		t.Fatalf("create share: status = %d", rr.Code)
	}

	req2 := httptest.NewRequest(http.MethodGet, "/api/shares/mine", nil)
	req2.Header.Set("Authorization", "Bearer "+token)
	rr2 := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr2, req2)

	if rr2.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rr2.Code, rr2.Body.String())
	}
	var resp struct {
		Shares []shareLinkResponse `json:"shares"`
	}
	json.NewDecoder(rr2.Body).Decode(&resp)
	if len(resp.Shares) != 1 {
		t.Errorf("len(shares) = %d, want 1", len(resp.Shares))
	}
}

// TestPublicShare_InfoEndpoint verifies GET /s/{token} returns file info.
func TestPublicShare_InfoEndpoint(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "publicshareuser")

	content := []byte("public file content")
	uploaded := uploadTestFile(t, env, token, "public.txt", content)

	// Create share.
	b, _ := json.Marshal(map[string]interface{}{})
	url := fmt.Sprintf("/api/files/%s/shares", uploaded.ID)
	req := httptest.NewRequest(http.MethodPost, url, bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)
	if rr.Code != http.StatusCreated {
		t.Fatalf("create share: status = %d", rr.Code)
	}
	var shareResp shareLinkResponse
	json.NewDecoder(rr.Body).Decode(&shareResp)

	// Access public info — no auth needed.
	infoURL := fmt.Sprintf("/s/%s", shareResp.Token)
	infoReq := httptest.NewRequest(http.MethodGet, infoURL, nil)
	infoRR := httptest.NewRecorder()
	env.server.Router().ServeHTTP(infoRR, infoReq)

	if infoRR.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", infoRR.Code, infoRR.Body.String())
	}

	var infoResp publicShareResponse
	if err := json.NewDecoder(infoRR.Body).Decode(&infoResp); err != nil {
		t.Fatalf("decode info response: %v", err)
	}
	if infoResp.Name != "public.txt" {
		t.Errorf("Name = %q, want public.txt", infoResp.Name)
	}
	if infoResp.Size != int64(len(content)) {
		t.Errorf("Size = %d, want %d", infoResp.Size, len(content))
	}
	if infoResp.HasPassword {
		t.Error("expected HasPassword = false")
	}
	if infoResp.Expired {
		t.Error("expected Expired = false")
	}
}

// TestPublicShare_Download verifies POST /s/{token}/download streams file content.
func TestPublicShare_Download(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "pubdluser")

	content := []byte("downloadable public content")
	uploaded := uploadTestFile(t, env, token, "pubdl.txt", content)

	// Create share.
	b, _ := json.Marshal(map[string]interface{}{})
	url := fmt.Sprintf("/api/files/%s/shares", uploaded.ID)
	req := httptest.NewRequest(http.MethodPost, url, bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)
	if rr.Code != http.StatusCreated {
		t.Fatalf("create share: status = %d", rr.Code)
	}
	var shareResp shareLinkResponse
	json.NewDecoder(rr.Body).Decode(&shareResp)

	// Public download — no auth needed.
	dlURL := fmt.Sprintf("/s/%s/download", shareResp.Token)
	dlReq := httptest.NewRequest(http.MethodPost, dlURL, bytes.NewReader([]byte("{}")))
	dlReq.Header.Set("Content-Type", "application/json")
	dlRR := httptest.NewRecorder()
	env.server.Router().ServeHTTP(dlRR, dlReq)

	if dlRR.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", dlRR.Code, dlRR.Body.String())
	}
	if !bytes.Equal(dlRR.Body.Bytes(), content) {
		t.Errorf("downloaded content = %q, want %q", dlRR.Body.Bytes(), content)
	}
}

// TestPublicShare_PasswordProtected verifies wrong password returns 401.
func TestPublicShare_PasswordProtected(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "pubpwuser")

	uploaded := uploadTestFile(t, env, token, "pwpub.txt", []byte("protected"))

	// Create share with password.
	b, _ := json.Marshal(map[string]interface{}{"password": "correct"})
	url := fmt.Sprintf("/api/files/%s/shares", uploaded.ID)
	req := httptest.NewRequest(http.MethodPost, url, bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)
	if rr.Code != http.StatusCreated {
		t.Fatalf("create share: status = %d", rr.Code)
	}
	var shareResp shareLinkResponse
	json.NewDecoder(rr.Body).Decode(&shareResp)

	// Try with wrong password.
	dlURL := fmt.Sprintf("/s/%s/download", shareResp.Token)
	wrongPwBody, _ := json.Marshal(map[string]string{"password": "wrong"})
	dlReq := httptest.NewRequest(http.MethodPost, dlURL, bytes.NewReader(wrongPwBody))
	dlReq.Header.Set("Content-Type", "application/json")
	dlRR := httptest.NewRecorder()
	env.server.Router().ServeHTTP(dlRR, dlReq)

	if dlRR.Code != http.StatusUnauthorized {
		t.Errorf("status = %d, want 401", dlRR.Code)
	}

	// Now with correct password.
	correctPwBody, _ := json.Marshal(map[string]string{"password": "correct"})
	dlReq2 := httptest.NewRequest(http.MethodPost, dlURL, bytes.NewReader(correctPwBody))
	dlReq2.Header.Set("Content-Type", "application/json")
	dlRR2 := httptest.NewRecorder()
	env.server.Router().ServeHTTP(dlRR2, dlReq2)

	if dlRR2.Code != http.StatusOK {
		t.Errorf("correct password: status = %d, want 200", dlRR2.Code)
	}
}

// TestPublicShare_DownloadLimit verifies download limit enforcement.
func TestPublicShare_DownloadLimit(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "pubdllimituser")

	uploaded := uploadTestFile(t, env, token, "limitdl.txt", []byte("limited content"))

	// Create share with max 1 download.
	b, _ := json.Marshal(map[string]interface{}{"max_downloads": 1})
	url := fmt.Sprintf("/api/files/%s/shares", uploaded.ID)
	req := httptest.NewRequest(http.MethodPost, url, bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)
	if rr.Code != http.StatusCreated {
		t.Fatalf("create share: status = %d", rr.Code)
	}
	var shareResp shareLinkResponse
	json.NewDecoder(rr.Body).Decode(&shareResp)

	// First download should succeed.
	dlURL := fmt.Sprintf("/s/%s/download", shareResp.Token)
	dlReq := httptest.NewRequest(http.MethodPost, dlURL, bytes.NewReader([]byte("{}")))
	dlReq.Header.Set("Content-Type", "application/json")
	dlRR := httptest.NewRecorder()
	env.server.Router().ServeHTTP(dlRR, dlReq)
	if dlRR.Code != http.StatusOK {
		t.Fatalf("first download: status = %d, want 200", dlRR.Code)
	}

	// Second download should be blocked.
	dlReq2 := httptest.NewRequest(http.MethodPost, dlURL, bytes.NewReader([]byte("{}")))
	dlReq2.Header.Set("Content-Type", "application/json")
	dlRR2 := httptest.NewRecorder()
	env.server.Router().ServeHTTP(dlRR2, dlReq2)
	if dlRR2.Code != http.StatusGone {
		t.Errorf("second download: status = %d, want 410", dlRR2.Code)
	}
}
