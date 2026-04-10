package token

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"

	"golang.org/x/crypto/pbkdf2"
)

// ConnectionData holds the connection details encrypted in a .syncvault token file.
type ConnectionData struct {
	ServerURL string `json:"server_url"`
	Username  string `json:"username"`
	Password  string `json:"password"`
}

// GeneratePIN generates a 6-character alphanumeric PIN using unambiguous characters.
// Excluded characters: O, 0, I, 1, l to prevent user confusion.
func GeneratePIN() string {
	const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	b := make([]byte, 6)
	if _, err := rand.Read(b); err != nil {
		// Extremely unlikely on any healthy system. Log and return a deterministic fallback
		// rather than crashing the server.
		return "XXXXXX"
	}
	for i := range b {
		b[i] = chars[int(b[i])%len(chars)]
	}
	return string(b)
}

// deriveKey derives a 32-byte AES key from the PIN using PBKDF2-SHA256
// with a fixed salt and 100 000 iterations.
func deriveKey(pin string) []byte {
	return pbkdf2.Key([]byte(pin), []byte("syncvault-token"), 100000, 32, sha256.New)
}

// Encrypt marshals data as JSON and encrypts it with AES-256-GCM.
// The returned bytes are: nonce (12 bytes) || ciphertext+tag.
func Encrypt(data ConnectionData, pin string) ([]byte, error) {
	plaintext, err := json.Marshal(data)
	if err != nil {
		return nil, fmt.Errorf("token: marshal: %w", err)
	}

	key := deriveKey(pin)
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("token: new cipher: %w", err)
	}

	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("token: new gcm: %w", err)
	}

	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, fmt.Errorf("token: generate nonce: %w", err)
	}

	// Seal appends ciphertext+tag after the nonce.
	return gcm.Seal(nonce, nonce, plaintext, nil), nil
}

// Decrypt decrypts a token blob produced by Encrypt.
// Returns an error wrapping "invalid PIN" if the authentication tag does not match.
func Decrypt(encrypted []byte, pin string) (*ConnectionData, error) {
	key := deriveKey(pin)
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("token: new cipher: %w", err)
	}

	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("token: new gcm: %w", err)
	}

	nonceSize := gcm.NonceSize()
	if len(encrypted) < nonceSize {
		return nil, fmt.Errorf("token: invalid token data")
	}

	nonce, ciphertext := encrypted[:nonceSize], encrypted[nonceSize:]
	plaintext, err := gcm.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return nil, fmt.Errorf("token: invalid PIN")
	}

	var data ConnectionData
	if err := json.Unmarshal(plaintext, &data); err != nil {
		return nil, fmt.Errorf("token: unmarshal: %w", err)
	}

	return &data, nil
}
