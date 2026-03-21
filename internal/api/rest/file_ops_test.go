package rest

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestUpdateFile_Rename verifies PUT /api/files/{id} renames a file.
func TestUpdateFile_Rename(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "renameuser")

	uploaded := uploadTestFile(t, env, token, "original.txt", []byte("content"))

	body := map[string]string{"name": "renamed.txt"}
	b, _ := json.Marshal(body)

	url := fmt.Sprintf("/api/files/%s", uploaded.ID)
	req := httptest.NewRequest(http.MethodPut, url, bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rr.Code, rr.Body.String())
	}

	var resp fileResponse
	json.NewDecoder(rr.Body).Decode(&resp)
	if resp.Name != "renamed.txt" {
		t.Errorf("Name = %q, want renamed.txt", resp.Name)
	}
}

// TestUpdateFile_NotFound verifies 404 when file doesn't exist.
func TestUpdateFile_NotFound(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "renamenfuser")

	body := map[string]string{"name": "new.txt"}
	b, _ := json.Marshal(body)

	req := httptest.NewRequest(http.MethodPut, "/api/files/nonexistent", bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404", rr.Code)
	}
}

// TestSoftDeleteFile verifies DELETE /api/files/{id} soft-deletes a file.
func TestSoftDeleteFile(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "softdeluser")

	uploaded := uploadTestFile(t, env, token, "todelete.txt", []byte("delete me"))

	url := fmt.Sprintf("/api/files/%s", uploaded.ID)
	req := httptest.NewRequest(http.MethodDelete, url, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204; body = %s", rr.Code, rr.Body.String())
	}

	// Verify file no longer appears in list.
	listReq := httptest.NewRequest(http.MethodGet, "/api/files", nil)
	listReq.Header.Set("Authorization", "Bearer "+token)
	listRR := httptest.NewRecorder()
	env.server.Router().ServeHTTP(listRR, listReq)

	var listResp struct {
		Files []fileResponse `json:"files"`
	}
	json.NewDecoder(listRR.Body).Decode(&listResp)
	for _, f := range listResp.Files {
		if f.ID == uploaded.ID {
			t.Error("deleted file still appears in list")
		}
	}
}

// TestSoftDeleteFile_NotFound verifies 404 for non-existent file.
func TestSoftDeleteFile_NotFound(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "softdelnotfound")

	req := httptest.NewRequest(http.MethodDelete, "/api/files/nonexistent", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusNotFound {
		t.Errorf("status = %d, want 404", rr.Code)
	}
}

// TestRestoreFile verifies POST /api/files/{id}/restore restores a trashed file.
func TestRestoreFile(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "restorefileuser")

	uploaded := uploadTestFile(t, env, token, "restore.txt", []byte("restore me"))

	// Delete the file first.
	delURL := fmt.Sprintf("/api/files/%s", uploaded.ID)
	delReq := httptest.NewRequest(http.MethodDelete, delURL, nil)
	delReq.Header.Set("Authorization", "Bearer "+token)
	delRR := httptest.NewRecorder()
	env.server.Router().ServeHTTP(delRR, delReq)
	if delRR.Code != http.StatusNoContent {
		t.Fatalf("delete: status = %d", delRR.Code)
	}

	// Verify it's in trash.
	trashReq := httptest.NewRequest(http.MethodGet, "/api/trash", nil)
	trashReq.Header.Set("Authorization", "Bearer "+token)
	trashRR := httptest.NewRecorder()
	env.server.Router().ServeHTTP(trashRR, trashReq)
	if trashRR.Code != http.StatusOK {
		t.Fatalf("trash list: status = %d", trashRR.Code)
	}
	var trashResp struct {
		Files []fileResponse `json:"files"`
	}
	json.NewDecoder(trashRR.Body).Decode(&trashResp)
	found := false
	for _, f := range trashResp.Files {
		if f.ID == uploaded.ID {
			found = true
			break
		}
	}
	if !found {
		t.Error("deleted file not found in trash")
	}

	// Restore the file.
	restoreURL := fmt.Sprintf("/api/files/%s/restore", uploaded.ID)
	restoreReq := httptest.NewRequest(http.MethodPost, restoreURL, nil)
	restoreReq.Header.Set("Authorization", "Bearer "+token)
	restoreRR := httptest.NewRecorder()
	env.server.Router().ServeHTTP(restoreRR, restoreReq)

	if restoreRR.Code != http.StatusOK {
		t.Fatalf("restore: status = %d, want 200; body = %s", restoreRR.Code, restoreRR.Body.String())
	}

	// Verify it's no longer in trash.
	trashReq2 := httptest.NewRequest(http.MethodGet, "/api/trash", nil)
	trashReq2.Header.Set("Authorization", "Bearer "+token)
	trashRR2 := httptest.NewRecorder()
	env.server.Router().ServeHTTP(trashRR2, trashReq2)
	var trashResp2 struct {
		Files []fileResponse `json:"files"`
	}
	json.NewDecoder(trashRR2.Body).Decode(&trashResp2)
	for _, f := range trashResp2.Files {
		if f.ID == uploaded.ID {
			t.Error("restored file still appears in trash")
		}
	}

	// Verify it's back in file list.
	listReq := httptest.NewRequest(http.MethodGet, "/api/files", nil)
	listReq.Header.Set("Authorization", "Bearer "+token)
	listRR := httptest.NewRecorder()
	env.server.Router().ServeHTTP(listRR, listReq)
	var listResp struct {
		Files []fileResponse `json:"files"`
	}
	json.NewDecoder(listRR.Body).Decode(&listResp)
	restoredFound := false
	for _, f := range listResp.Files {
		if f.ID == uploaded.ID {
			restoredFound = true
			break
		}
	}
	if !restoredFound {
		t.Error("restored file not found in file list")
	}
}

// TestListTrash verifies GET /api/trash lists trashed files for current user.
func TestListTrash(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "trashlistuser")

	// Upload and delete two files.
	f1 := uploadTestFile(t, env, token, "trash1.txt", []byte("trash1"))
	f2 := uploadTestFile(t, env, token, "trash2.txt", []byte("trash2"))

	for _, id := range []string{f1.ID, f2.ID} {
		req := httptest.NewRequest(http.MethodDelete, fmt.Sprintf("/api/files/%s", id), nil)
		req.Header.Set("Authorization", "Bearer "+token)
		rr := httptest.NewRecorder()
		env.server.Router().ServeHTTP(rr, req)
		if rr.Code != http.StatusNoContent {
			t.Fatalf("delete %s: status = %d", id, rr.Code)
		}
	}

	// List trash.
	req := httptest.NewRequest(http.MethodGet, "/api/trash", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body = %s", rr.Code, rr.Body.String())
	}

	var resp struct {
		Files []fileResponse `json:"files"`
	}
	json.NewDecoder(rr.Body).Decode(&resp)
	if len(resp.Files) != 2 {
		t.Errorf("len(files) = %d, want 2", len(resp.Files))
	}
}

// TestListTrash_IsolatedByUser verifies that trash is user-specific.
func TestListTrash_IsolatedByUser(t *testing.T) {
	env := newTestEnv(t)
	token1 := createUserAndToken(t, env, "trashuser1")
	token2 := createUserAndToken(t, env, "trashuser2")

	// User 1 uploads and deletes a file.
	f := uploadTestFile(t, env, token1, "u1trash.txt", []byte("user1 trash"))
	delReq := httptest.NewRequest(http.MethodDelete, fmt.Sprintf("/api/files/%s", f.ID), nil)
	delReq.Header.Set("Authorization", "Bearer "+token1)
	delRR := httptest.NewRecorder()
	env.server.Router().ServeHTTP(delRR, delReq)

	// User 2's trash should be empty.
	req := httptest.NewRequest(http.MethodGet, "/api/trash", nil)
	req.Header.Set("Authorization", "Bearer "+token2)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	var resp struct {
		Files []fileResponse `json:"files"`
	}
	json.NewDecoder(rr.Body).Decode(&resp)
	if len(resp.Files) != 0 {
		t.Errorf("user2 trash len = %d, want 0", len(resp.Files))
	}
}
