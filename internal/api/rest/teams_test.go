package rest

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

// createTeam is a helper that creates a team as admin and returns its response.
func createTeam(t *testing.T, env *testEnv, adminToken string, name string) teamResponse {
	t.Helper()
	b, _ := json.Marshal(map[string]string{"name": name})
	req := httptest.NewRequest(http.MethodPost, "/api/teams", bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+adminToken)
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)
	if rr.Code != http.StatusCreated {
		t.Fatalf("createTeam: status = %d, want 201; body = %s", rr.Code, rr.Body.String())
	}
	var resp teamResponse
	if err := json.NewDecoder(rr.Body).Decode(&resp); err != nil {
		t.Fatalf("decode team response: %v", err)
	}
	return resp
}

// TestCreateTeam verifies POST /api/teams (admin only) creates a team.
func TestCreateTeam(t *testing.T) {
	env := newTestEnv(t)
	_, adminToken := createAdminAndToken(t, env)

	team := createTeam(t, env, adminToken, "Engineering")
	if team.ID == "" {
		t.Error("expected non-empty team ID")
	}
	if team.Name != "Engineering" {
		t.Errorf("Name = %q, want Engineering", team.Name)
	}
}

// TestCreateTeam_NonAdmin_Forbidden verifies a regular user cannot create teams.
func TestCreateTeam_NonAdmin_Forbidden(t *testing.T) {
	env := newTestEnv(t)
	token := createUserAndToken(t, env, "teamnonadmin")

	b, _ := json.Marshal(map[string]string{"name": "Secret Team"})
	req := httptest.NewRequest(http.MethodPost, "/api/teams", bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusForbidden {
		t.Errorf("status = %d, want 403", rr.Code)
	}
}

// TestDeleteTeam verifies DELETE /api/teams/{id} (admin only) removes a team.
func TestDeleteTeam(t *testing.T) {
	env := newTestEnv(t)
	_, adminToken := createAdminAndToken(t, env)

	team := createTeam(t, env, adminToken, "ToDelete")

	url := fmt.Sprintf("/api/teams/%s", team.ID)
	req := httptest.NewRequest(http.MethodDelete, url, nil)
	req.Header.Set("Authorization", "Bearer "+adminToken)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusNoContent {
		t.Errorf("status = %d, want 204; body = %s", rr.Code, rr.Body.String())
	}
}

// TestListTeams_Admin verifies admin sees all teams.
func TestListTeams_Admin(t *testing.T) {
	env := newTestEnv(t)
	_, adminToken := createAdminAndToken(t, env)

	createTeam(t, env, adminToken, "Alpha")
	createTeam(t, env, adminToken, "Beta")

	req := httptest.NewRequest(http.MethodGet, "/api/teams", nil)
	req.Header.Set("Authorization", "Bearer "+adminToken)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	var resp struct {
		Teams []teamResponse `json:"teams"`
	}
	json.NewDecoder(rr.Body).Decode(&resp)
	if len(resp.Teams) != 2 {
		t.Errorf("len(teams) = %d, want 2", len(resp.Teams))
	}
}

// TestListTeams_User verifies regular user only sees permitted teams.
func TestListTeams_User(t *testing.T) {
	env := newTestEnv(t)
	adminID, adminToken := createAdminAndToken(t, env)
	_ = adminID

	// Create two teams.
	team1 := createTeam(t, env, adminToken, "Team1")
	createTeam(t, env, adminToken, "Team2")

	// Create a regular user.
	hashed, _ := env.db.GetUserByUsername("admin")
	_ = hashed
	userToken := createUserAndToken(t, env, "regularteamuser")
	userObj, _ := env.db.GetUserByUsername("regularteamuser")

	// Give user permission on only team1.
	if err := env.db.SetTeamPermission(team1.ID, userObj.ID, "read"); err != nil {
		t.Fatalf("SetTeamPermission: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/teams", nil)
	req.Header.Set("Authorization", "Bearer "+userToken)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rr.Code)
	}
	var resp struct {
		Teams []teamResponse `json:"teams"`
	}
	json.NewDecoder(rr.Body).Decode(&resp)
	if len(resp.Teams) != 1 {
		t.Errorf("len(teams) = %d, want 1 (user should only see permitted teams)", len(resp.Teams))
	}
}

// TestSetAndListTeamMembers verifies PUT and GET /api/teams/{id}/members endpoints.
func TestSetAndListTeamMembers(t *testing.T) {
	env := newTestEnv(t)
	_, adminToken := createAdminAndToken(t, env)

	team := createTeam(t, env, adminToken, "MemberTeam")

	// Create a user to add.
	memberToken := createUserAndToken(t, env, "memberuser")
	_ = memberToken
	memberUser, _ := env.db.GetUserByUsername("memberuser")

	// Set member.
	putURL := fmt.Sprintf("/api/teams/%s/members/%s", team.ID, memberUser.ID)
	b, _ := json.Marshal(map[string]string{"permission": "write"})
	putReq := httptest.NewRequest(http.MethodPut, putURL, bytes.NewReader(b))
	putReq.Header.Set("Authorization", "Bearer "+adminToken)
	putReq.Header.Set("Content-Type", "application/json")
	putRR := httptest.NewRecorder()
	env.server.Router().ServeHTTP(putRR, putReq)

	if putRR.Code != http.StatusOK {
		t.Fatalf("set member: status = %d, want 200; body = %s", putRR.Code, putRR.Body.String())
	}

	// List members.
	listURL := fmt.Sprintf("/api/teams/%s/members", team.ID)
	listReq := httptest.NewRequest(http.MethodGet, listURL, nil)
	listReq.Header.Set("Authorization", "Bearer "+adminToken)
	listRR := httptest.NewRecorder()
	env.server.Router().ServeHTTP(listRR, listReq)

	if listRR.Code != http.StatusOK {
		t.Fatalf("list members: status = %d, want 200", listRR.Code)
	}
	var listResp struct {
		Members []teamMemberResponse `json:"members"`
	}
	json.NewDecoder(listRR.Body).Decode(&listResp)
	if len(listResp.Members) != 1 {
		t.Fatalf("len(members) = %d, want 1", len(listResp.Members))
	}
	if listResp.Members[0].Permission != "write" {
		t.Errorf("Permission = %q, want write", listResp.Members[0].Permission)
	}
}

// TestRemoveTeamMember verifies DELETE /api/teams/{id}/members/{userId} removes a member.
func TestRemoveTeamMember(t *testing.T) {
	env := newTestEnv(t)
	_, adminToken := createAdminAndToken(t, env)

	team := createTeam(t, env, adminToken, "RemoveTeam")
	memberToken := createUserAndToken(t, env, "removemember")
	_ = memberToken
	memberUser, _ := env.db.GetUserByUsername("removemember")

	// Add member.
	if err := env.db.SetTeamPermission(team.ID, memberUser.ID, "read"); err != nil {
		t.Fatalf("SetTeamPermission: %v", err)
	}

	// Remove member.
	delURL := fmt.Sprintf("/api/teams/%s/members/%s", team.ID, memberUser.ID)
	req := httptest.NewRequest(http.MethodDelete, delURL, nil)
	req.Header.Set("Authorization", "Bearer "+adminToken)
	rr := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rr, req)

	if rr.Code != http.StatusNoContent {
		t.Errorf("status = %d, want 204", rr.Code)
	}

	// Verify they're gone.
	listURL := fmt.Sprintf("/api/teams/%s/members", team.ID)
	listReq := httptest.NewRequest(http.MethodGet, listURL, nil)
	listReq.Header.Set("Authorization", "Bearer "+adminToken)
	listRR := httptest.NewRecorder()
	env.server.Router().ServeHTTP(listRR, listReq)
	var listResp struct {
		Members []teamMemberResponse `json:"members"`
	}
	json.NewDecoder(listRR.Body).Decode(&listResp)
	if len(listResp.Members) != 0 {
		t.Errorf("len(members) = %d, want 0 after removal", len(listResp.Members))
	}
}
