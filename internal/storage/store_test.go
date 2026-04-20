package storage

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestStore_PutGet_RoundTrip(t *testing.T) {
	dir := t.TempDir()
	s, err := NewStore(dir, 8)
	if err != nil {
		t.Fatal(err)
	}

	data := []byte("hello world, this is a test file")
	hash, size, err := s.Put(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("Put error: %v", err)
	}
	if hash == "" {
		t.Error("Put returned empty hash")
	}
	if size != int64(len(data)) {
		t.Errorf("Put size = %d, want %d", size, len(data))
	}

	var buf bytes.Buffer
	if err := s.Get(hash, &buf); err != nil {
		t.Fatalf("Get error: %v", err)
	}
	if !bytes.Equal(buf.Bytes(), data) {
		t.Errorf("Get returned different data than Put")
	}
}

func TestStore_Deduplication(t *testing.T) {
	dir := t.TempDir()
	s, err := NewStore(dir, 8)
	if err != nil {
		t.Fatal(err)
	}

	data := []byte("deduplicated content")
	hash1, _, err := s.Put(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	hash2, _, err := s.Put(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	if hash1 != hash2 {
		t.Errorf("same data produced different hashes: %s vs %s", hash1, hash2)
	}
}

func TestStore_GetNotFound(t *testing.T) {
	dir := t.TempDir()
	s, err := NewStore(dir, 8)
	if err != nil {
		t.Fatal(err)
	}

	var buf bytes.Buffer
	err = s.Get("aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899", &buf)
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("expected ErrNotFound, got %v", err)
	}
}

func TestStore_Delete(t *testing.T) {
	dir := t.TempDir()
	s, err := NewStore(dir, 8)
	if err != nil {
		t.Fatal(err)
	}

	data := []byte("data to delete")
	hash, _, err := s.Put(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}

	if err := s.Delete(hash); err != nil {
		t.Fatalf("Delete error: %v", err)
	}

	var buf bytes.Buffer
	err = s.Get(hash, &buf)
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("expected ErrNotFound after delete, got %v", err)
	}
}

func TestStore_DeleteNotFound(t *testing.T) {
	dir := t.TempDir()
	s, err := NewStore(dir, 8)
	if err != nil {
		t.Fatal(err)
	}
	err = s.Delete("aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899")
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("expected ErrNotFound, got %v", err)
	}
}

func TestStore_LargeFileRoundTrip(t *testing.T) {
	dir := t.TempDir()
	s, err := NewStore(dir, 1024) // 1KB chunks
	if err != nil {
		t.Fatal(err)
	}

	// 1MB of data
	data := []byte(strings.Repeat("abcdefghijklmnopqrstuvwxyz0123456789", 28000))
	hash, size, err := s.Put(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("Put large file error: %v", err)
	}
	if size != int64(len(data)) {
		t.Errorf("size = %d, want %d", size, len(data))
	}
	_ = hash

	var buf bytes.Buffer
	if err := s.Get(hash, &buf); err != nil {
		t.Fatalf("Get large file error: %v", err)
	}
	if !bytes.Equal(buf.Bytes(), data) {
		t.Error("large file round-trip data mismatch")
	}
}

func TestStore_PutDirect_RoundTrip(t *testing.T) {
	dir := t.TempDir()
	s, err := NewStore(dir, 4*1024*1024)
	if err != nil {
		t.Fatal(err)
	}
	data := bytes.Repeat([]byte{0xAB}, 16*1024) // 16 KB
	hash, size, err := s.PutDirect(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("PutDirect error: %v", err)
	}
	if size != int64(len(data)) {
		t.Errorf("PutDirect size = %d, want %d", size, len(data))
	}
	var buf bytes.Buffer
	if err := s.GetDirect(hash, &buf); err != nil {
		t.Fatalf("GetDirect error: %v", err)
	}
	if !bytes.Equal(buf.Bytes(), data) {
		t.Error("PutDirect round-trip data mismatch")
	}
}

func TestStore_PutDirect_TempFileCleanedUpOnError(t *testing.T) {
	dir := t.TempDir()
	s, err := NewStore(dir, 4*1024*1024)
	if err != nil {
		t.Fatal(err)
	}
	// Reader that errors after some bytes
	er := &errReader{data: []byte("partial"), errAt: 7}
	_, _, err = s.PutDirect(er)
	if err == nil {
		t.Fatal("expected error from partial read")
	}
	// incoming/ should not contain any stale temp files
	incoming := filepath.Join(dir, "incoming")
	entries, _ := os.ReadDir(incoming)
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".tmp") {
			t.Errorf("stale temp file not cleaned up: %s", e.Name())
		}
	}
}

func TestStore_CleanupIncoming(t *testing.T) {
	dir := t.TempDir()
	s, err := NewStore(dir, 4*1024*1024)
	if err != nil {
		t.Fatal(err)
	}
	incoming := filepath.Join(dir, "incoming")
	_ = os.MkdirAll(incoming, 0755)
	// Stale file (simulated old mtime)
	stale := filepath.Join(incoming, "old.tmp")
	_ = os.WriteFile(stale, []byte("stale"), 0644)
	oldTime := time.Now().Add(-48 * time.Hour)
	_ = os.Chtimes(stale, oldTime, oldTime)
	// Fresh file (should be kept)
	fresh := filepath.Join(incoming, "new.tmp")
	_ = os.WriteFile(fresh, []byte("fresh"), 0644)

	removed, freed := s.CleanupIncoming(24 * time.Hour)
	if removed != 1 {
		t.Errorf("removed = %d, want 1", removed)
	}
	if freed != int64(len("stale")) {
		t.Errorf("freed = %d, want %d", freed, len("stale"))
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Errorf("stale file should have been deleted")
	}
	if _, err := os.Stat(fresh); err != nil {
		t.Errorf("fresh file should still exist: %v", err)
	}
}

// errReader is an io.Reader that returns a hard error after errAt bytes.
type errReader struct {
	data  []byte
	errAt int
	pos   int
}

func (r *errReader) Read(p []byte) (int, error) {
	if r.pos >= r.errAt {
		return 0, errors.New("simulated read failure")
	}
	n := copy(p, r.data[r.pos:])
	r.pos += n
	return n, nil
}
