package rest

import (
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
	"github.com/NielHeesakkers/SyncVault/internal/metadata"
	"github.com/go-chi/chi/v5"
)

// adminUserResponse is the JSON representation of a user with storage stats.
type adminUserResponse struct {
	ID           string    `json:"id"`
	Username     string    `json:"username"`
	Email        string    `json:"email"`
	Role         string    `json:"role"`
	QuotaBytes   int64     `json:"quota_bytes"`
	StorageUsed  int64     `json:"storage_used"`
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"updated_at"`
}

// handleAdminListUsers handles GET /api/admin/users.
func (s *Server) handleAdminListUsers(w http.ResponseWriter, r *http.Request) {
	users, err := s.db.ListUsers()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not list users"})
		return
	}

	result := make([]adminUserResponse, 0, len(users))
	for _, u := range users {
		used, err := s.db.StorageUsedByUser(u.ID)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not compute storage usage"})
			return
		}
		result = append(result, adminUserResponse{
			ID:          u.ID,
			Username:    u.Username,
			Email:       u.Email,
			Role:        u.Role,
			QuotaBytes:  u.QuotaBytes,
			StorageUsed: used,
			CreatedAt:   u.CreatedAt,
			UpdatedAt:   u.UpdatedAt,
		})
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"users": result})
}

// updateUserRequest is the body for PUT /api/admin/users/{id}.
type updateUserRequest struct {
	Email      string `json:"email"`
	Role       string `json:"role"`
	QuotaBytes *int64 `json:"quota_bytes"`
}

// handleAdminUpdateUser handles PUT /api/admin/users/{id}.
func (s *Server) handleAdminUpdateUser(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	user, err := s.db.GetUserByID(id)
	if err != nil {
		if errors.Is(err, metadata.ErrUserNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "user not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get user"})
		return
	}

	var req updateUserRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	if req.Email != "" {
		user.Email = req.Email
	}
	if req.Role != "" {
		user.Role = req.Role
	}
	if req.QuotaBytes != nil {
		user.QuotaBytes = *req.QuotaBytes
	}

	if err := s.db.UpdateUser(user); err != nil {
		if errors.Is(err, metadata.ErrDuplicateUser) {
			writeJSON(w, http.StatusConflict, map[string]string{"error": "email already exists"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not update user"})
		return
	}

	writeJSON(w, http.StatusOK, adminUserResponse{
		ID:         user.ID,
		Username:   user.Username,
		Email:      user.Email,
		Role:       user.Role,
		QuotaBytes: user.QuotaBytes,
		CreatedAt:  user.CreatedAt,
		UpdatedAt:  user.UpdatedAt,
	})
}

// handleAdminDeleteUser handles DELETE /api/admin/users/{id}.
func (s *Server) handleAdminDeleteUser(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	if err := s.db.DeleteUser(id); err != nil {
		if errors.Is(err, metadata.ErrUserNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "user not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not delete user"})
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

// resetPasswordRequest is the body for POST /api/admin/users/{id}/reset-password.
type resetPasswordRequest struct {
	Password string `json:"password"`
}

// handleAdminResetPassword handles POST /api/admin/users/{id}/reset-password.
func (s *Server) handleAdminResetPassword(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	user, err := s.db.GetUserByID(id)
	if err != nil {
		if errors.Is(err, metadata.ErrUserNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "user not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get user"})
		return
	}

	var req resetPasswordRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	if req.Password == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "password is required"})
		return
	}

	hashed, err := auth.HashPassword(req.Password)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not hash password"})
		return
	}

	user.Password = hashed
	if err := s.db.UpdateUser(user); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not update password"})
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "password updated"})
}

// storageOverviewResponse is the JSON response for GET /api/admin/storage.
type storageOverviewResponse struct {
	TotalUsers   int   `json:"total_users"`
	TotalUsed    int64 `json:"total_used_bytes"`
	TotalQuota   int64 `json:"total_quota_bytes"`
}

// handleAdminStorage handles GET /api/admin/storage.
func (s *Server) handleAdminStorage(w http.ResponseWriter, r *http.Request) {
	users, err := s.db.ListUsers()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not list users"})
		return
	}

	var totalUsed, totalQuota int64
	for _, u := range users {
		used, err := s.db.StorageUsedByUser(u.ID)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not compute storage usage"})
			return
		}
		totalUsed += used
		totalQuota += u.QuotaBytes
	}

	writeJSON(w, http.StatusOK, storageOverviewResponse{
		TotalUsers: len(users),
		TotalUsed:  totalUsed,
		TotalQuota: totalQuota,
	})
}

// handleAdminActivity handles GET /api/admin/activity.
func (s *Server) handleAdminActivity(w http.ResponseWriter, r *http.Request) {
	q := metadata.ActivityQuery{}

	q.UserID = r.URL.Query().Get("user_id")
	q.Action = r.URL.Query().Get("action")

	if limitStr := r.URL.Query().Get("limit"); limitStr != "" {
		if limit, err := strconv.Atoi(limitStr); err == nil {
			q.Limit = limit
		}
	}
	if offsetStr := r.URL.Query().Get("offset"); offsetStr != "" {
		if offset, err := strconv.Atoi(offsetStr); err == nil {
			q.Offset = offset
		}
	}

	entries, err := s.db.QueryActivity(q)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not query activity"})
		return
	}

	if entries == nil {
		entries = []metadata.ActivityEntry{}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"activity": entries})
}
