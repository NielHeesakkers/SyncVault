package rest

import (
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
	"github.com/NielHeesakkers/SyncVault/internal/metadata"
	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
)

// createTaskRequest is the body for POST /api/tasks.
type createTaskRequest struct {
	Name      string `json:"name"`
	Type      string `json:"type"`
	LocalPath string `json:"local_path"`
	FolderID  string `json:"folder_id"` // optional: use existing folder instead of auto-creating
}

// taskResponse is the response returned when a task is created or listed.
type taskResponse struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	Type       string `json:"type"`
	LocalPath  string `json:"local_path,omitempty"`
	Status     string `json:"status"`
	FolderID   string `json:"folder_id"`
	FolderName string `json:"folder_name"`
}

// toTaskResponse converts a SyncTask and folder name into a taskResponse.
func toTaskResponse(t *metadata.SyncTask, folderName string) taskResponse {
	return taskResponse{
		ID:         t.ID,
		Name:       t.Name,
		Type:       t.Type,
		LocalPath:  t.LocalPath,
		Status:     t.Status,
		FolderID:   t.FolderID,
		FolderName: folderName,
	}
}

// folderNameForTask builds the folder name from the task type and name.
// e.g. type="sync", name="Documents" → "Sync-Documents"
// e.g. type="ondemand" → "OnDemand"
func folderNameForTask(taskType, taskName string) string {
	switch taskType {
	case "ondemand":
		return "OnDemand"
	case "backup":
		return fmt.Sprintf("Backup-%s", taskName)
	default: // "sync"
		return fmt.Sprintf("Sync-%s", taskName)
	}
}

// handleListTasks handles GET /api/tasks.
// Admins can filter by folder_id to find tasks for any user's folder.
func (s *Server) handleListTasks(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())

	// Admin can search by folder_id across all users
	if folderID := r.URL.Query().Get("folder_id"); folderID != "" && claims.Role == "admin" {
		task, err := s.db.GetSyncTaskByFolderID(folderID)
		if err != nil || task == nil {
			writeJSON(w, http.StatusOK, []taskResponse{})
			return
		}
		folder, _ := s.db.GetFileByID(task.FolderID)
		folderName := ""
		if folder != nil {
			folderName = folder.Name
		}
		writeJSON(w, http.StatusOK, []taskResponse{toTaskResponse(task, folderName)})
		return
	}

	tasks, err := s.db.ListSyncTasks(claims.UserID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not list tasks"})
		return
	}

	resp := make([]taskResponse, 0, len(tasks))
	for i := range tasks {
		t := &tasks[i]
		folder, err := s.db.GetFileByID(t.FolderID)
		folderName := ""
		if err == nil {
			folderName = folder.Name
		}
		resp = append(resp, toTaskResponse(t, folderName))
	}

	writeJSON(w, http.StatusOK, resp)
}

// handleCreateTask handles POST /api/tasks.
func (s *Server) handleCreateTask(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())

	var req createTaskRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	req.Name = strings.TrimSpace(req.Name)
	req.Type = strings.ToLower(strings.TrimSpace(req.Type))

	if req.Type == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "type is required"})
		return
	}
	if req.Type != "sync" && req.Type != "backup" && req.Type != "ondemand" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "type must be sync, backup, or ondemand"})
		return
	}
	if req.Type != "ondemand" && req.Name == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "name is required for sync and backup tasks"})
		return
	}

	// Use "OnDemand" as the task name for ondemand tasks.
	taskName := req.Name
	if req.Type == "ondemand" {
		taskName = "OnDemand"
	}

	// Delete any existing task with the same name and type for this user (handles re-creation after app reinstall)
	// Skip for ondemand — those have a separate one-per-user check
	if req.Type != "ondemand" {
		s.db.DeleteSyncTaskByName(claims.UserID, taskName)
	}

	var subFolder *metadata.File

	if req.FolderID != "" {
		// Use an existing folder — verify it exists and belongs to the user.
		folder, err := s.db.GetFileByID(req.FolderID)
		if err != nil {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "folder not found"})
			return
		}
		if folder.OwnerID != claims.UserID {
			writeJSON(w, http.StatusForbidden, map[string]string{"error": "folder does not belong to you"})
			return
		}
		if !folder.IsDir {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "specified ID is not a folder"})
			return
		}
		subFolder = folder
	} else {
		// Auto-create a subfolder under the user's root folder (legacy behavior).
		rootFolder, err := s.db.GetUserRootFolder(claims.UserID)
		if err != nil {
			if errors.Is(err, metadata.ErrRootFolderNotFound) {
				writeJSON(w, http.StatusConflict, map[string]string{"error": "user root folder not found; cannot create task"})
				return
			}
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not find user root folder"})
			return
		}

		subFolderName := folderNameForTask(req.Type, taskName)

		// CreateFile for directories is idempotent: it returns the existing folder if one exists.
		created, createErr := s.db.CreateFile(rootFolder.ID, claims.UserID, subFolderName, true, 0, "", "")
		if createErr != nil {
			if errors.Is(createErr, metadata.ErrDuplicateFile) {
				// A soft-deleted folder with this name exists; find and restore it.
				existing, findErr := s.db.FindFileByName(rootFolder.ID, claims.UserID, subFolderName)
				if findErr != nil || existing == nil {
					writeJSON(w, http.StatusConflict, map[string]string{"error": "a folder with this name already exists"})
					return
				}
				if existing.DeletedAt.Valid {
					_ = s.db.RestoreFile(existing.ID)
					_ = s.db.UnmarkRemovedLocally(existing.ID)
				}
				subFolder = existing
			} else {
				writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not create task folder"})
				return
			}
		} else {
			subFolder = created
		}
	}

	// Create the sync task record.
	task, err := s.db.CreateSyncTask(claims.UserID, subFolder.ID, taskName, req.Type, req.LocalPath)
	if err != nil {
		if errors.Is(err, metadata.ErrDuplicateTask) {
			// Roll back the folder we just created.
			_ = s.db.SoftDeleteFile(subFolder.ID)
			writeJSON(w, http.StatusConflict, map[string]string{"error": "a task with this name already exists"})
			return
		}
		// Roll back the folder we just created.
		_ = s.db.SoftDeleteFile(subFolder.ID)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not create task"})
		return
	}

	// Apply default Smart Retention policy.
	_ = s.db.SetRetentionPolicy(metadata.RetentionPolicy{
		ID:            uuid.New().String(),
		SyncTaskID:    task.ID,
		DailyDays:     90,
		WeeklyWeeks:   24,
		MonthlyMonths: 12,
		MaxVersions:   10,
	})

	writeJSON(w, http.StatusCreated, toTaskResponse(task, subFolder.Name))
}

// handleDeleteTask handles DELETE /api/tasks/{id}.
// The associated folder is kept for safety; only the task record is removed.
func (s *Server) handleDeleteTask(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	id := chi.URLParam(r, "id")

	// Verify the task exists and belongs to the requesting user.
	task, err := s.db.GetSyncTask(id)
	if err != nil {
		if errors.Is(err, metadata.ErrTaskNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "task not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get task"})
		return
	}
	if task.UserID != claims.UserID {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "forbidden"})
		return
	}

	if err := s.db.DeleteSyncTask(id); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not delete task"})
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}

// handleGetRetention handles GET /api/tasks/{id}/retention.
func (s *Server) handleGetRetention(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	id := chi.URLParam(r, "id")

	task, err := s.db.GetSyncTask(id)
	if err != nil {
		if errors.Is(err, metadata.ErrTaskNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "task not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get task"})
		return
	}
	if task.UserID != claims.UserID && claims.Role != "admin" {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "forbidden"})
		return
	}

	policy, err := s.db.GetRetentionPolicy(id)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get retention policy"})
		return
	}

	if policy == nil {
		// Return defaults: keep everything
		writeJSON(w, http.StatusOK, metadata.RetentionPolicy{
			SyncTaskID:    id,
			HourlyHours:   0,
			DailyDays:     0,
			WeeklyWeeks:   0,
			MonthlyMonths: 0,
			YearlyYears:   0,
			MaxVersions:   0,
		})
		return
	}

	writeJSON(w, http.StatusOK, policy)
}

// handleSetRetention handles PUT /api/tasks/{id}/retention.
func (s *Server) handleSetRetention(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	id := chi.URLParam(r, "id")

	task, err := s.db.GetSyncTask(id)
	if err != nil {
		if errors.Is(err, metadata.ErrTaskNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "task not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get task"})
		return
	}
	if task.UserID != claims.UserID && claims.Role != "admin" {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "forbidden"})
		return
	}

	var req struct {
		HourlyHours   int `json:"hourly_hours"`
		DailyDays     int `json:"daily_days"`
		WeeklyWeeks   int `json:"weekly_weeks"`
		MonthlyMonths int `json:"monthly_months"`
		YearlyYears   int `json:"yearly_years"`
		MaxVersions   int `json:"max_versions"`
	}
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	policy := metadata.RetentionPolicy{
		SyncTaskID:    id,
		HourlyHours:   req.HourlyHours,
		DailyDays:     req.DailyDays,
		WeeklyWeeks:   req.WeeklyWeeks,
		MonthlyMonths: req.MonthlyMonths,
		YearlyYears:   req.YearlyYears,
		MaxVersions:   req.MaxVersions,
	}

	if err := s.db.SetRetentionPolicy(policy); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not save retention policy"})
		return
	}

	writeJSON(w, http.StatusOK, policy)
}
