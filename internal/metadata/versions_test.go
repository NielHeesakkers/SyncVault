package metadata

import (
	"errors"
	"testing"
	"time"
)

// mustCreateFile is a test helper that creates a file record for version tests.
func mustCreateFile(t *testing.T, db *DB, ownerID, name string) *File {
	t.Helper()
	f, err := db.CreateFile("", ownerID, name, false, 0, "initialhash", "text/plain")
	if err != nil {
		t.Fatalf("CreateFile(%q): %v", name, err)
	}
	return f
}

func TestCreateVersion(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "alice_v")
	f := mustCreateFile(t, db, u.ID, "doc.txt")

	v, err := db.CreateVersion(f.ID, 1, "contentHash1", "", 1024, u.ID)
	if err != nil {
		t.Fatalf("CreateVersion: %v", err)
	}
	if v.ID == "" {
		t.Error("expected non-empty ID")
	}
	if v.FileID != f.ID {
		t.Errorf("FileID = %q, want %q", v.FileID, f.ID)
	}
	if v.VersionNum != 1 {
		t.Errorf("VersionNum = %d, want 1", v.VersionNum)
	}
	if v.ContentHash != "contentHash1" {
		t.Errorf("ContentHash = %q, want contentHash1", v.ContentHash)
	}
	if v.PatchHash.Valid {
		t.Errorf("PatchHash should be NULL when empty string passed, got %q", v.PatchHash.String)
	}
	if v.Size != 1024 {
		t.Errorf("Size = %d, want 1024", v.Size)
	}
}

func TestCreateVersion_WithPatchHash(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "bob_v")
	f := mustCreateFile(t, db, u.ID, "data.bin")

	v, err := db.CreateVersion(f.ID, 1, "contentHash", "patchHash1", 512, u.ID)
	if err != nil {
		t.Fatalf("CreateVersion: %v", err)
	}
	if !v.PatchHash.Valid || v.PatchHash.String != "patchHash1" {
		t.Errorf("PatchHash = %v, want patchHash1", v.PatchHash)
	}
}

func TestListVersions_NewestFirst(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "carol_v")
	f := mustCreateFile(t, db, u.ID, "report.txt")

	db.CreateVersion(f.ID, 1, "hash1", "", 100, u.ID)
	db.CreateVersion(f.ID, 2, "hash2", "", 200, u.ID)
	db.CreateVersion(f.ID, 3, "hash3", "", 300, u.ID)

	versions, err := db.ListVersions(f.ID)
	if err != nil {
		t.Fatalf("ListVersions: %v", err)
	}
	if len(versions) != 3 {
		t.Fatalf("len(versions) = %d, want 3", len(versions))
	}
	// Newest first: version_num 3, 2, 1.
	if versions[0].VersionNum != 3 {
		t.Errorf("versions[0].VersionNum = %d, want 3", versions[0].VersionNum)
	}
	if versions[1].VersionNum != 2 {
		t.Errorf("versions[1].VersionNum = %d, want 2", versions[1].VersionNum)
	}
	if versions[2].VersionNum != 1 {
		t.Errorf("versions[2].VersionNum = %d, want 1", versions[2].VersionNum)
	}
}

func TestGetLatestVersion(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "dave_v")
	f := mustCreateFile(t, db, u.ID, "latest.txt")

	db.CreateVersion(f.ID, 1, "hash1", "", 100, u.ID)
	db.CreateVersion(f.ID, 2, "hash2", "", 200, u.ID)

	v, err := db.GetLatestVersion(f.ID)
	if err != nil {
		t.Fatalf("GetLatestVersion: %v", err)
	}
	if v.VersionNum != 2 {
		t.Errorf("VersionNum = %d, want 2", v.VersionNum)
	}
}

func TestGetLatestVersion_NotFound(t *testing.T) {
	db := openTestDB(t)
	_, err := db.GetLatestVersion("nonexistent-file-id")
	if !errors.Is(err, ErrVersionNotFound) {
		t.Errorf("expected ErrVersionNotFound, got %v", err)
	}
}

func TestGetVersionByNum(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "eve_v")
	f := mustCreateFile(t, db, u.ID, "bynum.txt")

	db.CreateVersion(f.ID, 1, "hash1", "", 100, u.ID)
	db.CreateVersion(f.ID, 2, "hash2", "", 200, u.ID)

	v, err := db.GetVersionByNum(f.ID, 1)
	if err != nil {
		t.Fatalf("GetVersionByNum: %v", err)
	}
	if v.ContentHash != "hash1" {
		t.Errorf("ContentHash = %q, want hash1", v.ContentHash)
	}
}

func TestGetVersionByNum_NotFound(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "frank_v")
	f := mustCreateFile(t, db, u.ID, "nope.txt")

	_, err := db.GetVersionByNum(f.ID, 99)
	if !errors.Is(err, ErrVersionNotFound) {
		t.Errorf("expected ErrVersionNotFound, got %v", err)
	}
}

func TestCountVersions(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "grace_v")
	f := mustCreateFile(t, db, u.ID, "count.txt")

	n, err := db.CountVersions(f.ID)
	if err != nil {
		t.Fatalf("CountVersions: %v", err)
	}
	if n != 0 {
		t.Errorf("CountVersions = %d, want 0", n)
	}

	db.CreateVersion(f.ID, 1, "h1", "", 10, u.ID)
	db.CreateVersion(f.ID, 2, "h2", "", 20, u.ID)

	n, err = db.CountVersions(f.ID)
	if err != nil {
		t.Fatalf("CountVersions: %v", err)
	}
	if n != 2 {
		t.Errorf("CountVersions = %d, want 2", n)
	}
}

func TestDeleteOldestVersion(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "henry_v")
	f := mustCreateFile(t, db, u.ID, "oldest.txt")

	db.CreateVersion(f.ID, 1, "h1", "", 10, u.ID)
	db.CreateVersion(f.ID, 2, "h2", "", 20, u.ID)
	db.CreateVersion(f.ID, 3, "h3", "", 30, u.ID)

	if err := db.DeleteOldestVersion(f.ID); err != nil {
		t.Fatalf("DeleteOldestVersion: %v", err)
	}

	n, _ := db.CountVersions(f.ID)
	if n != 2 {
		t.Errorf("CountVersions after delete = %d, want 2", n)
	}

	// Version 1 should be gone.
	_, err := db.GetVersionByNum(f.ID, 1)
	if !errors.Is(err, ErrVersionNotFound) {
		t.Errorf("expected ErrVersionNotFound for deleted version, got %v", err)
	}
}

func TestDeleteOldestVersion_NotFound(t *testing.T) {
	db := openTestDB(t)
	err := db.DeleteOldestVersion("nonexistent-file-id")
	if !errors.Is(err, ErrVersionNotFound) {
		t.Errorf("expected ErrVersionNotFound, got %v", err)
	}
}

func TestDeleteVersion(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "iris_v")
	f := mustCreateFile(t, db, u.ID, "byid.txt")

	v, _ := db.CreateVersion(f.ID, 1, "h1", "", 10, u.ID)
	db.CreateVersion(f.ID, 2, "h2", "", 20, u.ID)

	if err := db.DeleteVersion(v.ID); err != nil {
		t.Fatalf("DeleteVersion: %v", err)
	}

	n, _ := db.CountVersions(f.ID)
	if n != 1 {
		t.Errorf("CountVersions after DeleteVersion = %d, want 1", n)
	}
}

func TestDeleteVersion_NotFound(t *testing.T) {
	db := openTestDB(t)
	err := db.DeleteVersion("nonexistent-id")
	if !errors.Is(err, ErrVersionNotFound) {
		t.Errorf("expected ErrVersionNotFound, got %v", err)
	}
}

func TestDeleteVersionsOlderThan(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "jane_v")
	f := mustCreateFile(t, db, u.ID, "prune.txt")

	db.CreateVersion(f.ID, 1, "h1", "", 10, u.ID)
	db.CreateVersion(f.ID, 2, "h2", "", 20, u.ID)
	db.CreateVersion(f.ID, 3, "h3", "", 30, u.ID)

	// Delete versions older than far future — should delete all.
	deleted, err := db.DeleteVersionsOlderThan(f.ID, time.Now().UTC().Add(time.Hour))
	if err != nil {
		t.Fatalf("DeleteVersionsOlderThan: %v", err)
	}
	if deleted != 3 {
		t.Errorf("deleted = %d, want 3", deleted)
	}

	n, _ := db.CountVersions(f.ID)
	if n != 0 {
		t.Errorf("CountVersions after prune = %d, want 0", n)
	}
}
