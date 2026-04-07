package auth

import "golang.org/x/crypto/bcrypt"

// HashPassword hashes the given password using bcrypt.
// Cost 4 is used for fast login on low-power Docker containers (e.g. ARM Mac Mini).
// This is acceptable for a self-hosted private server behind authentication.
func HashPassword(password string) (string, error) {
	bytes, err := bcrypt.GenerateFromPassword([]byte(password), 4)
	if err != nil {
		return "", err
	}
	return string(bytes), nil
}

// CheckPassword reports whether password matches the bcrypt hash.
func CheckPassword(password, hash string) bool {
	err := bcrypt.CompareHashAndPassword([]byte(hash), []byte(password))
	return err == nil
}

// NeedsRehash returns true if the hash was generated with a higher cost than current.
func NeedsRehash(hash string) bool {
	cost, err := bcrypt.Cost([]byte(hash))
	if err != nil {
		return false
	}
	return cost > 4
}
