package token

import (
	"strings"
	"testing"
)

// TestEncryptDecryptRoundTrip verifies that data encrypted with a PIN
// can be decrypted correctly with the same PIN.
func TestEncryptDecryptRoundTrip(t *testing.T) {
	data := ConnectionData{
		ServerURL: "https://sync.example.com",
		Username:  "alice",
		Password:  "s3cr3t!",
	}
	pin := "ABC123"

	encrypted, err := Encrypt(data, pin)
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	if len(encrypted) == 0 {
		t.Fatal("Encrypt returned empty bytes")
	}

	got, err := Decrypt(encrypted, pin)
	if err != nil {
		t.Fatalf("Decrypt: %v", err)
	}

	if got.ServerURL != data.ServerURL {
		t.Errorf("ServerURL: got %q, want %q", got.ServerURL, data.ServerURL)
	}
	if got.Username != data.Username {
		t.Errorf("Username: got %q, want %q", got.Username, data.Username)
	}
	if got.Password != data.Password {
		t.Errorf("Password: got %q, want %q", got.Password, data.Password)
	}
}

// TestDecryptWrongPINFails verifies that decrypting with the wrong PIN returns an error.
func TestDecryptWrongPINFails(t *testing.T) {
	data := ConnectionData{
		ServerURL: "https://sync.example.com",
		Username:  "bob",
		Password:  "hunter2",
	}

	encrypted, err := Encrypt(data, "RIGHT1")
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	_, err = Decrypt(encrypted, "WRONG2")
	if err == nil {
		t.Fatal("expected error when decrypting with wrong PIN, got nil")
	}
	if !strings.Contains(err.Error(), "invalid PIN") {
		t.Errorf("expected 'invalid PIN' in error, got %q", err.Error())
	}
}

// TestDecryptTruncatedData verifies that truncated data returns an error
// rather than panicking.
func TestDecryptTruncatedData(t *testing.T) {
	_, err := Decrypt([]byte{0x01, 0x02}, "ABCDEF")
	if err == nil {
		t.Fatal("expected error for truncated data, got nil")
	}
}

// TestGeneratePINLength verifies that GeneratePIN returns a 6-character string.
func TestGeneratePINLength(t *testing.T) {
	pin := GeneratePIN()
	if len(pin) != 6 {
		t.Errorf("GeneratePIN length: got %d, want 6", len(pin))
	}
}

// TestGeneratePINCharset verifies that GeneratePIN only uses the allowed character set
// and never includes ambiguous characters (O, 0, I, 1, l).
func TestGeneratePINCharset(t *testing.T) {
	const allowed = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	const ambiguous = "O0I1l"

	// Generate many PINs to get good coverage.
	for i := 0; i < 1000; i++ {
		pin := GeneratePIN()
		for _, c := range pin {
			if !strings.ContainsRune(allowed, c) {
				t.Errorf("PIN %q contains disallowed character %q", pin, c)
			}
			if strings.ContainsRune(ambiguous, c) {
				t.Errorf("PIN %q contains ambiguous character %q", pin, c)
			}
		}
	}
}

// TestEncryptProducesUniqueNonces verifies that two encryptions of the same data
// yield different ciphertexts (random nonce).
func TestEncryptProducesUniqueNonces(t *testing.T) {
	data := ConnectionData{ServerURL: "https://example.com", Username: "u", Password: "p"}
	pin := "ZZZZZZ"

	a, err := Encrypt(data, pin)
	if err != nil {
		t.Fatalf("Encrypt a: %v", err)
	}
	b, err := Encrypt(data, pin)
	if err != nil {
		t.Fatalf("Encrypt b: %v", err)
	}

	if string(a) == string(b) {
		t.Error("expected different ciphertexts for two encryptions (nonces must be random)")
	}
}
