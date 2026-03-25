package auth

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"
)

type contextKey string

const claimsKey contextKey = "claims"

// TokenInvalidationChecker checks if a user's tokens have been invalidated.
type TokenInvalidationChecker interface {
	GetTokenInvalidatedAt(userID string) (*time.Time, error)
}

// RequireAuth returns middleware that validates a Bearer access token and
// stores the resulting Claims in the request context.
// If checker is provided, it also verifies the token was issued after any invalidation.
func RequireAuth(j *JWT, checker ...TokenInvalidationChecker) func(http.Handler) http.Handler {
	var chk TokenInvalidationChecker
	if len(checker) > 0 {
		chk = checker[0]
	}

	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			authHeader := r.Header.Get("Authorization")
			if authHeader == "" {
				writeJSONError(w, http.StatusUnauthorized, "missing authorization header")
				return
			}

			parts := strings.SplitN(authHeader, " ", 2)
			if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
				writeJSONError(w, http.StatusUnauthorized, "invalid authorization header format")
				return
			}

			claims, err := j.ValidateAccessToken(parts[1])
			if err != nil {
				writeJSONError(w, http.StatusUnauthorized, "invalid or expired token")
				return
			}

			// Check if tokens have been invalidated (e.g. password changed)
			if chk != nil {
				invalidatedAt, err := chk.GetTokenInvalidatedAt(claims.UserID)
				if err == nil && invalidatedAt != nil && claims.IssuedAt.Before(*invalidatedAt) {
					writeJSONError(w, http.StatusUnauthorized, "session expired — please log in again")
					return
				}
			}

			ctx := context.WithValue(r.Context(), claimsKey, claims)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// RequireAdmin middleware checks that the request's claims have role "admin".
// It must be chained after RequireAuth.
func RequireAdmin(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		claims := GetClaims(r.Context())
		if claims == nil || claims.Role != "admin" {
			writeJSONError(w, http.StatusForbidden, "admin access required")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// GetClaims retrieves Claims from the context, or nil if absent.
func GetClaims(ctx context.Context) *Claims {
	v := ctx.Value(claimsKey)
	if v == nil {
		return nil
	}
	c, _ := v.(*Claims)
	return c
}

func writeJSONError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": message})
}
