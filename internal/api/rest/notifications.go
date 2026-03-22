package rest

import (
	"net/http"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
	"github.com/go-chi/chi/v5"
)

// handleListNotifications handles GET /api/notifications.
func (s *Server) handleListNotifications(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())

	notifications, err := s.db.ListNotifications(claims.UserID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not list notifications"})
		return
	}

	unread, _ := s.db.CountUnreadNotifications(claims.UserID)

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"notifications": notifications,
		"unread_count":  unread,
	})
}

// handleAcceptNotification handles POST /api/notifications/{id}/accept.
func (s *Server) handleAcceptNotification(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	id := chi.URLParam(r, "id")

	notif, err := s.db.GetNotification(id)
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "notification not found"})
		return
	}
	if notif.UserID != claims.UserID {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "forbidden"})
		return
	}

	_ = s.db.MarkNotificationActed(id)
	writeJSON(w, http.StatusOK, map[string]string{"status": "accepted"})
}

// handleDeclineNotification handles POST /api/notifications/{id}/decline.
func (s *Server) handleDeclineNotification(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	id := chi.URLParam(r, "id")

	notif, err := s.db.GetNotification(id)
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "notification not found"})
		return
	}
	if notif.UserID != claims.UserID {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "forbidden"})
		return
	}

	_ = s.db.MarkNotificationActed(id)
	writeJSON(w, http.StatusOK, map[string]string{"status": "declined"})
}

// handleMarkAllRead handles POST /api/notifications/read.
func (s *Server) handleMarkAllRead(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	_ = s.db.MarkAllNotificationsRead(claims.UserID)
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// handleListMyTeams handles GET /api/teams/mine.
func (s *Server) handleListMyTeams(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())

	teams, err := s.db.ListUserTeamFolders(claims.UserID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not list teams"})
		return
	}

	type teamWithPerm struct {
		ID         string `json:"id"`
		Name       string `json:"name"`
		Permission string `json:"permission"`
	}

	result := make([]teamWithPerm, 0, len(teams))
	for _, t := range teams {
		perm, _ := s.db.GetTeamPermission(t.ID, claims.UserID)
		result = append(result, teamWithPerm{
			ID:         t.ID,
			Name:       t.Name,
			Permission: perm,
		})
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"teams": result})
}

// handleListTeamFiles handles GET /api/teams/{id}/files.
// Returns the files inside a team folder. The team folder's file entry uses the team ID as owner_id.
func (s *Server) handleListTeamFiles(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	teamID := chi.URLParam(r, "id")

	// Verify user has access to this team
	_, err := s.db.GetTeamPermission(teamID, claims.UserID)
	if err != nil {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "no access to this team folder"})
		return
	}

	// Find the team's file folder (owner_id = team ID, parent_id NULL, is_dir = 1)
	// Then list its children
	parentID := r.URL.Query().Get("parent_id")

	if parentID == "" {
		// Find the root team folder
		files, err := s.db.ListChildren("")
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not list files"})
			return
		}
		// Find the team's root folder
		for _, f := range files {
			if f.OwnerID == teamID && f.IsDir {
				parentID = f.ID
				break
			}
		}
		if parentID == "" {
			writeJSON(w, http.StatusOK, map[string]interface{}{"files": []interface{}{}})
			return
		}
	}

	children, err := s.db.ListChildren(parentID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not list files"})
		return
	}

	result := make([]fileResponse, 0, len(children))
	for _, f := range children {
		result = append(result, toFileResponse(f))
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"files": result})
}
