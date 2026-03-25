package rest

import (
	"net/http"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
	"github.com/NielHeesakkers/SyncVault/internal/metadata"
	"github.com/go-chi/chi/v5"
)

// syncStateRequest is a single item in the PUT /api/sync-state body.
type syncStateRequest struct {
	FilePath    string `json:"file_path"`
	ContentHash string `json:"content_hash"`
	SyncedAt    string `json:"synced_at"`
}

// syncStateResponse is the JSON representation of a single sync state entry.
type syncStateResponse struct {
	FilePath    string `json:"file_path"`
	ContentHash string `json:"content_hash"`
	SyncedAt    string `json:"synced_at"`
}

// handlePutSyncState handles PUT /api/sync-state/{deviceID}/{taskName}.
// Accepts a JSON array of {file_path, content_hash, synced_at} and upserts them.
func (s *Server) handlePutSyncState(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	deviceID := chi.URLParam(r, "deviceID")
	taskName := chi.URLParam(r, "taskName")

	var items []syncStateRequest
	if err := readJSON(r, &items); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	states := make([]metadata.SyncState, 0, len(items))
	for _, item := range items {
		states = append(states, metadata.SyncState{
			FilePath:    item.FilePath,
			ContentHash: item.ContentHash,
			SyncedAt:    item.SyncedAt,
		})
	}

	if err := s.db.SaveSyncStates(claims.UserID, deviceID, taskName, states); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not save sync states"})
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// handleGetSyncState handles GET /api/sync-state/{deviceID}/{taskName}.
// Returns all sync states for the authenticated user, device, and task.
func (s *Server) handleGetSyncState(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	deviceID := chi.URLParam(r, "deviceID")
	taskName := chi.URLParam(r, "taskName")

	states, err := s.db.GetSyncStates(claims.UserID, deviceID, taskName)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get sync states"})
		return
	}

	result := make([]syncStateResponse, 0, len(states))
	for _, s := range states {
		result = append(result, syncStateResponse{
			FilePath:    s.FilePath,
			ContentHash: s.ContentHash,
			SyncedAt:    s.SyncedAt,
		})
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"states": result})
}

// handleDeleteSyncState handles DELETE /api/sync-state/{deviceID}/{taskName}.
// Removes all sync states for the authenticated user, device, and task.
func (s *Server) handleDeleteSyncState(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	deviceID := chi.URLParam(r, "deviceID")
	taskName := chi.URLParam(r, "taskName")

	if err := s.db.DeleteSyncStates(claims.UserID, deviceID, taskName); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not delete sync states"})
		return
	}

	w.WriteHeader(http.StatusNoContent)
}
