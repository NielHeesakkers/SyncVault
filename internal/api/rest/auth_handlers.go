package rest

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
	"github.com/NielHeesakkers/SyncVault/internal/metadata"
	"github.com/NielHeesakkers/SyncVault/internal/token"
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

// handleAutoLogin validates a JWT token from query param and redirects to /files with auth set.
// Used by the macOS app to open the web UI without requiring manual login.
func (s *Server) handleAutoLogin(w http.ResponseWriter, r *http.Request) {
	tokenStr := r.URL.Query().Get("token")
	if tokenStr == "" {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}

	claims, err := s.jwt.ValidateAccessToken(tokenStr)
	if err != nil {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}

	// Generate fresh tokens for the session
	accessToken, refreshToken, err := s.jwt.GenerateTokens(claims.UserID, claims.Username, claims.Role)
	if err != nil {
		http.Redirect(w, r, "/login", http.StatusFound)
		return
	}

	// Return an HTML page that stores the tokens in localStorage and redirects to /files.
	// Encode values as JSON to prevent XSS from malicious usernames.
	userJSON, _ := json.Marshal(map[string]string{
		"id": claims.UserID, "username": claims.Username, "role": claims.Role,
	})
	atJSON, _ := json.Marshal(accessToken)
	rtJSON, _ := json.Marshal(refreshToken)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<!DOCTYPE html><html><head><script>
localStorage.setItem('access_token',%s);
localStorage.setItem('refresh_token',%s);
localStorage.setItem('user',JSON.stringify(%s));
window.location.href='/files';
</script></head><body>Redirecting...</body></html>`,
		atJSON, rtJSON, userJSON)
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

	// Auto-rehash with lower cost if the stored hash uses a higher cost (speeds up future logins)
	if auth.NeedsRehash(user.Password) {
		if newHash, err := auth.HashPassword(req.Password); err == nil {
			_ = s.db.UpdateUserPassword(user.ID, newHash)
		}
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

	// Invalidate all existing tokens so the user is logged out everywhere
	_ = s.db.InvalidateTokens(user.ID)

	writeJSON(w, http.StatusOK, map[string]string{"status": "password updated"})
}

// forgotPasswordRequest is the body for POST /api/auth/forgot-password.
type forgotPasswordRequest struct {
	Email string `json:"email"`
}

// handleForgotPassword initiates a password reset by sending a reset link to the user's email.
// It always returns 200 to prevent email enumeration.
func (s *Server) handleForgotPassword(w http.ResponseWriter, r *http.Request) {
	var req forgotPasswordRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	// Always return 200 regardless of whether the email exists.
	user, err := s.db.GetUserByEmail(req.Email)
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]string{"status": "if an account with this email exists, you will receive a reset link"})
		return
	}

	token, err := s.db.CreatePasswordReset(user.ID)
	if err != nil {
		log.Printf("password reset: could not create token for user %s: %v", user.ID, err)
		writeJSON(w, http.StatusOK, map[string]string{"status": "if an account with this email exists, you will receive a reset link"})
		return
	}

	if s.email != nil && s.email.Enabled() {
		baseURL, settingErr := s.db.GetSetting("base_url")
		if settingErr != nil {
			baseURL = ""
		}
		resetLink := fmt.Sprintf("%s/reset-password?token=%s", baseURL, token)
		if err := s.email.SendPasswordResetLink(user.Email, resetLink); err != nil {
			log.Printf("password reset: failed to send email to %s: %v", user.Email, err)
		}
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "if an account with this email exists, you will receive a reset link"})
}

// publicResetPasswordRequest is the body for POST /api/auth/reset-password.
type publicResetPasswordRequest struct {
	Token           string `json:"token"`
	Password        string `json:"password"`
	ConfirmPassword string `json:"confirm_password"`
}

// handleResetPassword validates a reset token and sets a new password for the user.
func (s *Server) handleResetPassword(w http.ResponseWriter, r *http.Request) {
	var req publicResetPasswordRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	if req.Token == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "token is required"})
		return
	}
	if req.Password == "" || req.ConfirmPassword == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "password and confirm_password are required"})
		return
	}
	if req.Password != req.ConfirmPassword {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "passwords do not match"})
		return
	}

	userID, err := s.db.ValidatePasswordReset(req.Token)
	if err != nil {
		switch {
		case errors.Is(err, metadata.ErrPasswordResetNotFound):
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid or expired reset token"})
		case errors.Is(err, metadata.ErrPasswordResetExpired):
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "reset token has expired"})
		case errors.Is(err, metadata.ErrPasswordResetUsed):
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "reset token has already been used"})
		default:
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
		}
		return
	}

	user, err := s.db.GetUserByID(userID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not load user"})
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

	if err := s.db.InvalidateTokens(userID); err != nil {
		log.Printf("password reset: could not invalidate tokens: %v", err)
	}

	if err := s.db.MarkPasswordResetUsed(req.Token); err != nil {
		log.Printf("password reset: could not mark token used: %v", err)
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "password reset successfully"})
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

	// Create user's root folder.
	if _, err := s.db.CreateFile("", user.ID, user.Username, true, 0, "", ""); err != nil {
		log.Printf("warning: could not create user root folder: %v", err)
	}

	// Generate connection token and store it; log but do not fail on error.
	pin := ""
	{
		baseURL, _ := s.db.GetSetting("base_url")
		if baseURL == "" {
			// Fallback: derive from the request Host header.
			scheme := "https"
			if r.TLS == nil {
				scheme = "http"
			}
			baseURL = scheme + "://" + r.Host
		}

		connData := token.ConnectionData{
			ServerURL: baseURL,
			Username:  req.Username,
			Password:  req.Password,
		}

		generatedPIN := token.GeneratePIN()
		encrypted, err := token.Encrypt(connData, generatedPIN)
		if err != nil {
			log.Printf("token: failed to encrypt connection token for user %s: %v", user.ID, err)
		} else {
			if err := s.db.SaveConnectionToken(user.ID, encrypted); err != nil {
				log.Printf("token: failed to save connection token for user %s: %v", user.ID, err)
			} else {
				pin = generatedPIN
			}
		}
	}

	// Send welcome email; log but do not fail on error.
	if s.email != nil && s.email.Enabled() {
		if err := s.email.SendWelcome(user.Email, user.Username, req.Password, pin); err != nil {
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
