package auth

import (
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

func newTestJWT() *JWT {
	return NewJWT("test-secret-key-for-testing")
}

func TestGenerateTokens_NonEmpty(t *testing.T) {
	j := newTestJWT()
	access, refresh, err := j.GenerateTokens("user1", "alice", "member")
	if err != nil {
		t.Fatalf("GenerateTokens returned error: %v", err)
	}
	if access == "" {
		t.Fatal("expected non-empty access token")
	}
	if refresh == "" {
		t.Fatal("expected non-empty refresh token")
	}
}

func TestGenerateTokens_Different(t *testing.T) {
	j := newTestJWT()
	access, refresh, err := j.GenerateTokens("user1", "alice", "member")
	if err != nil {
		t.Fatalf("GenerateTokens returned error: %v", err)
	}
	if access == refresh {
		t.Fatal("access token and refresh token must be different")
	}
}

func TestValidateAccessToken_CorrectClaims(t *testing.T) {
	j := newTestJWT()
	access, _, err := j.GenerateTokens("user42", "bob", "admin")
	if err != nil {
		t.Fatalf("GenerateTokens returned error: %v", err)
	}

	claims, err := j.ValidateAccessToken(access)
	if err != nil {
		t.Fatalf("ValidateAccessToken returned error: %v", err)
	}
	if claims.UserID != "user42" {
		t.Errorf("expected UserID 'user42', got '%s'", claims.UserID)
	}
	if claims.Username != "bob" {
		t.Errorf("expected Username 'bob', got '%s'", claims.Username)
	}
	if claims.Role != "admin" {
		t.Errorf("expected Role 'admin', got '%s'", claims.Role)
	}
}

func TestValidateRefreshToken_CorrectClaims(t *testing.T) {
	j := newTestJWT()
	_, refresh, err := j.GenerateTokens("user99", "carol", "member")
	if err != nil {
		t.Fatalf("GenerateTokens returned error: %v", err)
	}

	claims, err := j.ValidateRefreshToken(refresh)
	if err != nil {
		t.Fatalf("ValidateRefreshToken returned error: %v", err)
	}
	if claims.UserID != "user99" {
		t.Errorf("expected UserID 'user99', got '%s'", claims.UserID)
	}
	if claims.Username != "carol" {
		t.Errorf("expected Username 'carol', got '%s'", claims.Username)
	}
	if claims.Role != "member" {
		t.Errorf("expected Role 'member', got '%s'", claims.Role)
	}
}

func TestValidateAccessToken_ExpiredToken(t *testing.T) {
	j := newTestJWT()

	// Build an already-expired access token manually.
	past := time.Now().Add(-1 * time.Hour)
	tc := tokenClaims{
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    issuer,
			Subject:   "user1",
			IssuedAt:  jwt.NewNumericDate(past.Add(-time.Hour)),
			ExpiresAt: jwt.NewNumericDate(past),
		},
		UserID:   "user1",
		Username: "alice",
		Role:     "member",
		Type:     tokenTypeAccess,
	}
	tokenStr, err := jwt.NewWithClaims(jwt.SigningMethodHS256, tc).SignedString(j.secret)
	if err != nil {
		t.Fatalf("failed to create expired token: %v", err)
	}

	_, err = j.ValidateAccessToken(tokenStr)
	if err != ErrExpiredToken {
		t.Errorf("expected ErrExpiredToken, got %v", err)
	}
}

func TestValidateAccessToken_WrongSecret(t *testing.T) {
	j1 := NewJWT("secret-one")
	j2 := NewJWT("secret-two")

	access, _, err := j1.GenerateTokens("user1", "alice", "member")
	if err != nil {
		t.Fatalf("GenerateTokens returned error: %v", err)
	}

	_, err = j2.ValidateAccessToken(access)
	if err != ErrInvalidToken {
		t.Errorf("expected ErrInvalidToken for wrong secret, got %v", err)
	}
}

func TestValidateAccessToken_RefreshAsAccess(t *testing.T) {
	j := newTestJWT()
	_, refresh, err := j.GenerateTokens("user1", "alice", "member")
	if err != nil {
		t.Fatalf("GenerateTokens returned error: %v", err)
	}

	_, err = j.ValidateAccessToken(refresh)
	if err != ErrInvalidToken {
		t.Errorf("expected ErrInvalidToken when using refresh token as access token, got %v", err)
	}
}
