package storage

import (
	"bytes"
	"errors"
	"strings"
	"testing"
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
