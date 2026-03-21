package rest

import (
	"errors"
	"log"
	"net/http"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
	"github.com/NielHeesakkers/SyncVault/internal/metadata"
)

// loginRequest is the body for POST /api/auth/login.
type loginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

// loginResponse is the body returned on successful login.
type loginResponse struct {
	AccessToken  string   `json:"access_token"`
	RefreshToken string   `json:"refresh_token"`
	User         userInfo `json:"user"`
}

// userInfo is the public user representation.
type userInfo struct {
	ID       string `json:"id"`
	Username string `json:"username"`
	Email    string `json:"email"`
	Role     string `json:"role"`
}

// handleLogin authenticates a user and returns a token pair.
func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	var req loginRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	user, err := s.db.GetUserByUsername(req.Username)
	if err != nil {
		if errors.Is(err, metadata.ErrUserNotFound) {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid credentials"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		return
	}

	if !auth.CheckPassword(req.Password, user.Password) {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid credentials"})
		return
	}

	accessToken, refreshToken, err := s.jwt.GenerateTokens(user.ID, user.Username, user.Role)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not generate tokens"})
		return
	}

	writeJSON(w, http.StatusOK, loginResponse{
		AccessToken:  accessToken,
		RefreshToken: refreshToken,
		User: userInfo{
			ID:       user.ID,
			Username: user.Username,
			Email:    user.Email,
			Role:     user.Role,
		},
	})
}

// refreshRequest is the body for POST /api/auth/refresh.
type refreshRequest struct {
	RefreshToken string `json:"refresh_token"`
}

// handleRefresh validates a refresh token and issues a new token pair.
func (s *Server) handleRefresh(w http.ResponseWriter, r *http.Request) {
	var req refreshRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	claims, err := s.jwt.ValidateRefreshToken(req.RefreshToken)
	if err != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid or expired refresh token"})
		return
	}

	accessToken, refreshToken, err := s.jwt.GenerateTokens(claims.UserID, claims.Username, claims.Role)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not generate tokens"})
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{
		"access_token":  accessToken,
		"refresh_token": refreshToken,
	})
}

// changeMyPasswordRequest is the body for PUT /api/me/password.
type changeMyPasswordRequest struct {
	CurrentPassword string `json:"current_password"`
	NewPassword     string `json:"new_password"`
}

// handleChangeMyPassword handles PUT /api/me/password.
// It verifies the current password before updating to the new one.
func (s *Server) handleChangeMyPassword(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())

	var req changeMyPasswordRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	if req.CurrentPassword == "" || req.NewPassword == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "current_password and new_password are required"})
		return
	}

	user, err := s.db.GetUserByID(claims.UserID)
	if err != nil {
		if errors.Is(err, metadata.ErrUserNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "user not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get user"})
		return
	}

	if !auth.CheckPassword(req.CurrentPassword, user.Password) {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "current password is incorrect"})
		return
	}

	hashed, err := auth.HashPassword(req.NewPassword)
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

// createUserRequest is the body for POST /api/users.
type createUserRequest struct {
	Username string `json:"username"`
	Email    string `json:"email"`
	Password string `json:"password"`
	Role     string `json:"role"`
}

// handleCreateUser creates a new user (admin only).
func (s *Server) handleCreateUser(w http.ResponseWriter, r *http.Request) {
	var req createUserRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	hashed, err := auth.HashPassword(req.Password)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not hash password"})
		return
	}

	role := req.Role
	if role == "" {
		role = "user"
	}

	user, err := s.db.CreateUser(req.Username, req.Email, hashed, role)
	if err != nil {
		if errors.Is(err, metadata.ErrDuplicateUser) {
			writeJSON(w, http.StatusConflict, map[string]string{"error": "username or email already exists"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not create user"})
		return
	}

	// Send welcome email; log but do not fail on error.
	if s.email != nil && s.email.Enabled() {
		if err := s.email.SendWelcome(user.Email, user.Username, req.Password); err != nil {
			log.Printf("email: failed to send welcome email to %s: %v", user.Email, err)
		}
	}

	writeJSON(w, http.StatusCreated, userInfo{
		ID:       user.ID,
		Username: user.Username,
		Email:    user.Email,
		Role:     user.Role,
	})
}
