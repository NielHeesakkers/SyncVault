package auth

import (
	"errors"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// Sentinel errors returned by token validation.
var (
	ErrInvalidToken = errors.New("invalid token")
	ErrExpiredToken = errors.New("token has expired")
)

const (
	accessTokenTTL  = 24 * time.Hour
	refreshTokenTTL = 7 * 24 * time.Hour
	issuer          = "syncvault"
	tokenTypeAccess  = "access"
	tokenTypeRefresh = "refresh"
)

// Claims holds the public fields extracted from a validated token.
type Claims struct {
	UserID   string
	Username string
	Role     string
}

// tokenClaims is the internal JWT claims structure.
type tokenClaims struct {
	jwt.RegisteredClaims
	UserID   string `json:"user_id"`
	Username string `json:"username"`
	Role     string `json:"role"`
	Type     string `json:"type"`
}

// JWT manages token generation and validation.
type JWT struct {
	secret []byte
}

// NewJWT creates a new JWT manager with the given signing secret.
func NewJWT(secret string) *JWT {
	return &JWT{secret: []byte(secret)}
}

// GenerateTokens generates a new access token and refresh token for the given user.
func (j *JWT) GenerateTokens(userID, username, role string) (accessToken, refreshToken string, err error) {
	now := time.Now()

	accessClaims := tokenClaims{
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    issuer,
			Subject:   userID,
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(accessTokenTTL)),
		},
		UserID:   userID,
		Username: username,
		Role:     role,
		Type:     tokenTypeAccess,
	}

	accessToken, err = jwt.NewWithClaims(jwt.SigningMethodHS256, accessClaims).SignedString(j.secret)
	if err != nil {
		return "", "", err
	}

	refreshClaims := tokenClaims{
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    issuer,
			Subject:   userID,
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(refreshTokenTTL)),
		},
		UserID:   userID,
		Username: username,
		Role:     role,
		Type:     tokenTypeRefresh,
	}

	refreshToken, err = jwt.NewWithClaims(jwt.SigningMethodHS256, refreshClaims).SignedString(j.secret)
	if err != nil {
		return "", "", err
	}

	return accessToken, refreshToken, nil
}

// ValidateAccessToken parses and validates an access token, returning its Claims.
func (j *JWT) ValidateAccessToken(tokenStr string) (*Claims, error) {
	return j.validateToken(tokenStr, tokenTypeAccess)
}

// ValidateRefreshToken parses and validates a refresh token, returning its Claims.
func (j *JWT) ValidateRefreshToken(tokenStr string) (*Claims, error) {
	return j.validateToken(tokenStr, tokenTypeRefresh)
}

func (j *JWT) validateToken(tokenStr, expectedType string) (*Claims, error) {
	tc := &tokenClaims{}

	token, err := jwt.ParseWithClaims(tokenStr, tc, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, ErrInvalidToken
		}
		return j.secret, nil
	})

	if err != nil {
		if errors.Is(err, jwt.ErrTokenExpired) {
			return nil, ErrExpiredToken
		}
		return nil, ErrInvalidToken
	}

	if !token.Valid {
		return nil, ErrInvalidToken
	}

	if tc.Type != expectedType {
		return nil, ErrInvalidToken
	}

	return &Claims{
		UserID:   tc.UserID,
		Username: tc.Username,
		Role:     tc.Role,
	}, nil
}
