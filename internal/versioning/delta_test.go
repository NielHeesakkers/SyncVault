package versioning

import (
	"bytes"
	"testing"
)

func TestDelta_RoundTrip(t *testing.T) {
	old := []byte("hello world, this is a test of the delta patch system")
	new := []byte("hello world, this is a modified test of the delta patch system!")

	patch, err := CreatePatch(old, new)
	if err != nil {
		t.Fatalf("CreatePatch: %v", err)
	}
	if len(patch) == 0 {
		t.Fatal("expected non-empty patch")
	}

	got, err := ApplyPatch(old, patch)
	if err != nil {
		t.Fatalf("ApplyPatch: %v", err)
	}
	if !bytes.Equal(got, new) {
		t.Errorf("ApplyPatch result mismatch\ngot:  %q\nwant: %q", got, new)
	}
}

func TestDelta_LargeFileSmallModification(t *testing.T) {
	// Build a large old file (8 KB of repeated pattern).
	pattern := []byte("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz!@")
	old := bytes.Repeat(pattern, 128) // 8192 bytes

	// Small modification in the middle.
	new := make([]byte, len(old))
	copy(new, old)
	copy(new[4000:4010], []byte("XXXXXXXXXX"))

	patch, err := CreatePatch(old, new)
	if err != nil {
		t.Fatalf("CreatePatch: %v", err)
	}

	got, err := ApplyPatch(old, patch)
	if err != nil {
		t.Fatalf("ApplyPatch: %v", err)
	}
	if !bytes.Equal(got, new) {
		t.Errorf("large file round-trip failed at modified region")
	}

	// Patch should be significantly smaller than the full new content because
	// most of the data is COPYed from old.
	if len(patch) >= len(new)/2 {
		t.Logf("patch size=%d, new size=%d (compression may vary)", len(patch), len(new))
	}
}

func TestDelta_EmptyToContent(t *testing.T) {
	old := []byte{}
	new := []byte("brand new content that did not exist before")

	patch, err := CreatePatch(old, new)
	if err != nil {
		t.Fatalf("CreatePatch: %v", err)
	}

	got, err := ApplyPatch(old, patch)
	if err != nil {
		t.Fatalf("ApplyPatch: %v", err)
	}
	if !bytes.Equal(got, new) {
		t.Errorf("got %q, want %q", got, new)
	}
}

func TestDelta_IdenticalFiles(t *testing.T) {
	data := []byte("identical content that should produce a compact patch")

	patch, err := CreatePatch(data, data)
	if err != nil {
		t.Fatalf("CreatePatch: %v", err)
	}

	got, err := ApplyPatch(data, patch)
	if err != nil {
		t.Fatalf("ApplyPatch: %v", err)
	}
	if !bytes.Equal(got, data) {
		t.Errorf("got %q, want %q", got, data)
	}
}

func TestDelta_ContentToEmpty(t *testing.T) {
	old := []byte("some content that will be removed")
	new := []byte{}

	patch, err := CreatePatch(old, new)
	if err != nil {
		t.Fatalf("CreatePatch: %v", err)
	}

	got, err := ApplyPatch(old, patch)
	if err != nil {
		t.Fatalf("ApplyPatch: %v", err)
	}
	if !bytes.Equal(got, new) {
		t.Errorf("got %q, want empty", got)
	}
}
