package rest

import (
	"errors"
	"net/http"
	"time"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
	"github.com/NielHeesakkers/SyncVault/internal/metadata"
	"github.com/go-chi/chi/v5"
)

// teamResponse is the JSON representation of a team folder.
type teamResponse struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	CreatedAt time.Time `json:"created_at"`
}

func toTeamResponse(tf metadata.TeamFolder) teamResponse {
	return teamResponse{
		ID:        tf.ID,
		Name:      tf.Name,
		CreatedAt: tf.CreatedAt,
	}
}

// teamMemberResponse is the JSON representation of a team member permission.
type teamMemberResponse struct {
	UserID     string `json:"user_id"`
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

	writeJSON(w, http.StatusCreated, toTeamResponse(*tf))
}

// handleDeleteTeam handles DELETE /api/teams/{id} (admin only).
func (s *Server) handleDeleteTeam(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

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
		result = append(result, teamMemberResponse{
			UserID:     p.UserID,
			Permission: p.Permission,
		})
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

	if req.Permission != "read" && req.Permission != "write" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "permission must be 'read' or 'write'"})
		return
	}

	if err := s.db.SetTeamPermission(teamID, userID, req.Permission); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not set team permission"})
		return
	}

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
