package storage

import (
	"os"
	"syscall"
	"testing"
	"time"
)

func TestPutBlock_RetryOnTooManyFiles(t *testing.T) {
	dir := t.TempDir()
	store, err := NewStore(dir, 4*1024*1024)
	if err != nil {
		t.Fatal("NewStore:", err)
	}

	// Get current limits
	var rlimit syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &rlimit); err != nil {
		t.Fatal("Getrlimit:", err)
	}
	oldSoft := rlimit.Cur
	t.Logf("Current ulimit: soft=%d hard=%d", rlimit.Cur, rlimit.Max)

	// Set soft limit very low to trigger EMFILE
	rlimit.Cur = 25
	if err := syscall.Setrlimit(syscall.RLIMIT_NOFILE, &rlimit); err != nil {
		t.Fatal("Setrlimit:", err)
	}
	defer func() {
		rlimit.Cur = oldSoft
		syscall.Setrlimit(syscall.RLIMIT_NOFILE, &rlimit)
	}()

	// Eat up file descriptors
	var holders []*os.File
	for i := 0; i < 20; i++ {
		f, err := os.CreateTemp(dir, "holder-*")
		if err != nil {
			t.Logf("Opened %d holder files before hitting limit", i)
			break
		}
		holders = append(holders, f)
	}

	// Release holders after 1.5 seconds — retry should pick this up
	go func() {
		time.Sleep(1500 * time.Millisecond)
		t.Log("Releasing file descriptors...")
		for _, f := range holders {
			f.Close()
		}
	}()

	// Try PutBlock — should fail initially with EMFILE, retry should succeed
	// SHA256("hello world") = b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9
	data := []byte("hello world")
	hash := "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"

	isNew, err := store.PutBlock(hash, data)
	if err != nil {
		t.Fatalf("PutBlock failed even with retry: %v", err)
	}
	if !isNew {
		t.Fatal("Expected isNew=true")
	}
	t.Log("PutBlock succeeded after retry!")

	if !store.HasBlock(hash) {
		t.Fatal("Block not found after PutBlock")
	}
}

func TestPutBlock_NormalOperation(t *testing.T) {
	dir := t.TempDir()
	store, err := NewStore(dir, 4*1024*1024)
	if err != nil {
		t.Fatal("NewStore:", err)
	}

	data := []byte("hello world")
	hash := "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"

	isNew, err := store.PutBlock(hash, data)
	if err != nil {
		t.Fatal("PutBlock:", err)
	}
	if !isNew {
		t.Fatal("Expected isNew=true on first write")
	}

	// Second write should dedup
	isNew, err = store.PutBlock(hash, data)
	if err != nil {
		t.Fatal("PutBlock dedup:", err)
	}
	if isNew {
		t.Fatal("Expected isNew=false on dedup")
	}
}
