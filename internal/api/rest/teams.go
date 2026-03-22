package rest

import (
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
	"github.com/NielHeesakkers/SyncVault/internal/metadata"
	"github.com/go-chi/chi/v5"
)

// teamResponse is the JSON representation of a team folder.
type teamResponse struct {
	ID         string    `json:"id"`
	Name       string    `json:"name"`
	QuotaBytes int64     `json:"quota_bytes"`
	CreatedAt  time.Time `json:"created_at"`
}

func toTeamResponse(tf metadata.TeamFolder) teamResponse {
	return teamResponse{
		ID:         tf.ID,
		Name:       tf.Name,
		QuotaBytes: tf.QuotaBytes,
		CreatedAt:  tf.CreatedAt,
	}
}

// handleUpdateTeam handles PUT /api/teams/{id} (admin only).
func (s *Server) handleUpdateTeam(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	var req struct {
		Name       string `json:"name"`
		QuotaBytes int64  `json:"quota_bytes"`
	}
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	team, err := s.db.GetTeamFolder(id)
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "team not found"})
		return
	}

	name := req.Name
	if name == "" {
		name = team.Name
	}

	if err := s.db.UpdateTeamFolder(id, name, req.QuotaBytes); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not update team"})
		return
	}

	team.Name = name
	team.QuotaBytes = req.QuotaBytes
	writeJSON(w, http.StatusOK, toTeamResponse(*team))
}

// teamMemberResponse is the JSON representation of a team member permission.
type teamMemberResponse struct {
	UserID     string `json:"user_id"`
	Username   string `json:"username,omitempty"`
	Permission string `json:"permission"`
}

// handleListTeams handles GET /api/teams.
// Admins see all teams; regular users see only teams they have a permission on.
func (s *Server) handleListTeams(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())

	var folders []metadata.TeamFolder
	var err error

	if claims.Role == "admin" {
		folders, err = s.db.ListTeamFolders()
	} else {
		folders, err = s.db.ListUserTeamFolders(claims.UserID)
	}

	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not list teams"})
		return
	}

	result := make([]teamResponse, 0, len(folders))
	for _, tf := range folders {
		result = append(result, toTeamResponse(tf))
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"teams": result})
}

// createTeamRequest is the body for POST /api/teams.
type createTeamRequest struct {
	Name string `json:"name"`
}

// handleCreateTeam handles POST /api/teams (admin only).
func (s *Server) handleCreateTeam(w http.ResponseWriter, r *http.Request) {
	var req createTeamRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	if req.Name == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "name is required"})
		return
	}

	tf, err := s.db.CreateTeamFolder(req.Name)
	if err != nil {
		if errors.Is(err, metadata.ErrDuplicateTeamFolder) {
			writeJSON(w, http.StatusConflict, map[string]string{"error": "team folder already exists"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not create team"})
		return
	}

	// Team folders are not owned by anyone — store with team folder ID as owner
	// so they appear at root level separate from user folders
	_, _ = s.db.CreateFile("", tf.ID, fmt.Sprintf("Team-%s", req.Name), true, 0, "", "")

	writeJSON(w, http.StatusCreated, toTeamResponse(*tf))
}

// handleTransferTeamFolder handles POST /api/teams/{id}/transfer (admin only).
// Transfers the team's file folder to a user's home folder.
func (s *Server) handleTransferTeamFolder(w http.ResponseWriter, r *http.Request) {
	teamID := chi.URLParam(r, "id")

	var req struct {
		UserID string `json:"user_id"`
	}
	if err := readJSON(r, &req); err != nil || req.UserID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "user_id is required"})
		return
	}

	// Find the team's file folder (owner_id = team ID)
	rootFiles, _ := s.db.ListChildren("")
	for _, f := range rootFiles {
		if f.OwnerID == teamID && f.IsDir {
			// Get user's home folder
			homeFolder, err := s.db.GetUserRootFolder(req.UserID)
			if err != nil {
				writeJSON(w, http.StatusBadRequest, map[string]string{"error": "user has no home folder"})
				return
			}
			// Move: change parent to user's home, change owner, keep name
			s.db.MoveFile(f.ID, homeFolder.ID, f.Name)
			s.db.UpdateFileOwner(f.ID, req.UserID)
			break
		}
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "transferred"})
}

// handleDeleteTeam handles DELETE /api/teams/{id} (admin only).
func (s *Server) handleDeleteTeam(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	// Find and soft-delete the team's file folder (owner_id = team ID, or name matches)
	team, _ := s.db.GetTeamFolder(id)
	if team != nil {
		teamFolderName := fmt.Sprintf("Team-%s", team.Name)
		rootFiles, _ := s.db.ListChildren("")
		for _, f := range rootFiles {
			if f.IsDir && (f.OwnerID == id || f.Name == teamFolderName) {
				_ = s.db.SoftDeleteFile(f.ID)
				break
			}
		}
	}

	if err := s.db.DeleteTeamFolder(id); err != nil {
		if errors.Is(err, metadata.ErrTeamFolderNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "team not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not delete team"})
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

// handleListTeamMembers handles GET /api/teams/{id}/members.
func (s *Server) handleListTeamMembers(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	perms, err := s.db.ListTeamPermissions(id)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not list team members"})
		return
	}

	result := make([]teamMemberResponse, 0, len(perms))
	for _, p := range perms {
		r := teamMemberResponse{
			UserID:     p.UserID,
			Permission: p.Permission,
		}
		if u, err := s.db.GetUserByID(p.UserID); err == nil {
			r.Username = u.Username
		}
		result = append(result, r)
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"members": result})
}

// setTeamMemberRequest is the body for PUT /api/teams/{id}/members/{userId}.
type setTeamMemberRequest struct {
	Permission string `json:"permission"`
}

// handleSetTeamMember handles PUT /api/teams/{id}/members/{userId}.
func (s *Server) handleSetTeamMember(w http.ResponseWriter, r *http.Request) {
	teamID := chi.URLParam(r, "id")
	userID := chi.URLParam(r, "userId")

	var req setTeamMemberRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	if req.Permission != "read" && req.Permission != "write" && req.Permission != "readwrite" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "permission must be 'read', 'write', or 'readwrite'"})
		return
	}

	if err := s.db.SetTeamPermission(teamID, userID, req.Permission); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not set team permission"})
		return
	}

	// Send notification to user about team invite
	team, _ := s.db.GetTeamFolder(teamID)
	teamName := teamID
	if team != nil {
		teamName = team.Name
	}
	_, _ = s.db.CreateNotification(
		userID,
		"team_invite",
		"Team Folder Invite",
		fmt.Sprintf("You have been added to the team folder '%s' with %s access.", teamName, req.Permission),
		fmt.Sprintf(`{"team_id":"%s","team_name":"%s","permission":"%s"}`, teamID, teamName, req.Permission),
	)

	writeJSON(w, http.StatusOK, teamMemberResponse{
		UserID:     userID,
		Permission: req.Permission,
	})
}

// handleRemoveTeamMember handles DELETE /api/teams/{id}/members/{userId}.
func (s *Server) handleRemoveTeamMember(w http.ResponseWriter, r *http.Request) {
	teamID := chi.URLParam(r, "id")
	userID := chi.URLParam(r, "userId")

	if err := s.db.RemoveTeamPermission(teamID, userID); err != nil {
		if errors.Is(err, metadata.ErrPermissionNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "member not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not remove team member"})
		return
	}

	w.WriteHeader(http.StatusNoContent)
}
