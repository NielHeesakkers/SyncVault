package metadata

import (
	"errors"
	"testing"
	"time"
)

// helper: create a user for file tests
func mustCreateUser(t *testing.T, db *DB, username string) *User {
	t.Helper()
	u, err := db.CreateUser(username, username+"@test.com", "pw", "user")
	if err != nil {
		t.Fatalf("CreateUser(%q): %v", username, err)
	}
	return u
}

func TestCreateFolder(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "alice")

	dir, err := db.CreateFile("", u.ID, "Documents", true, 0, "", "")
	if err != nil {
		t.Fatalf("CreateFile (dir): %v", err)
	}
	if dir.ID == "" {
		t.Error("expected non-empty ID")
	}
	if !dir.IsDir {
		t.Error("expected IsDir=true")
	}
	if dir.ParentID.Valid {
		t.Error("expected NULL parent_id for root item")
	}
}

func TestCreateFile_WithParent(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "bob")

	parent, _ := db.CreateFile("", u.ID, "Docs", true, 0, "", "")
	f, err := db.CreateFile(parent.ID, u.ID, "readme.md", false, 512, "sha256hash", "text/markdown")
	if err != nil {
		t.Fatalf("CreateFile: %v", err)
	}
	if !f.ParentID.Valid || f.ParentID.String != parent.ID {
		t.Errorf("ParentID = %v, want %s", f.ParentID, parent.ID)
	}
	if f.Size != 512 {
		t.Errorf("Size = %d, want 512", f.Size)
	}
	if !f.ContentHash.Valid || f.ContentHash.String != "sha256hash" {
		t.Errorf("ContentHash = %v, want sha256hash", f.ContentHash)
	}
}

func TestListChildren(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "carol")

	parent, _ := db.CreateFile("", u.ID, "Root", true, 0, "", "")
	db.CreateFile(parent.ID, u.ID, "subdir", true, 0, "", "")
	db.CreateFile(parent.ID, u.ID, "alpha.txt", false, 100, "h1", "text/plain")
	db.CreateFile(parent.ID, u.ID, "beta.txt", false, 200, "h2", "text/plain")

	children, err := db.ListChildren(parent.ID)
	if err != nil {
		t.Fatalf("ListChildren: %v", err)
	}
	if len(children) != 3 {
		t.Fatalf("len(children) = %d, want 3", len(children))
	}
	// First entry should be the directory.
	if !children[0].IsDir {
		t.Errorf("expected first child to be a directory")
	}
	// Files should be sorted by name.
	if children[1].Name != "alpha.txt" {
		t.Errorf("children[1].Name = %q, want alpha.txt", children[1].Name)
	}
	if children[2].Name != "beta.txt" {
		t.Errorf("children[2].Name = %q, want beta.txt", children[2].Name)
	}
}

func TestGetFileByID(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "dave")
	f, _ := db.CreateFile("", u.ID, "notes.txt", false, 1024, "hash", "text/plain")

	got, err := db.GetFileByID(f.ID)
	if err != nil {
		t.Fatalf("GetFileByID: %v", err)
	}
	if got.Name != "notes.txt" {
		t.Errorf("Name = %q, want notes.txt", got.Name)
	}
}

func TestGetFileByID_NotFound(t *testing.T) {
	db := openTestDB(t)
	_, err := db.GetFileByID("nonexistent")
	if !errors.Is(err, ErrFileNotFound) {
		t.Errorf("expected ErrFileNotFound, got %v", err)
	}
}

func TestMoveFile(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "eve")

	dir1, _ := db.CreateFile("", u.ID, "Dir1", true, 0, "", "")
	dir2, _ := db.CreateFile("", u.ID, "Dir2", true, 0, "", "")
	f, _ := db.CreateFile(dir1.ID, u.ID, "file.txt", false, 100, "h", "text/plain")

	if err := db.MoveFile(f.ID, dir2.ID, "file.txt"); err != nil {
		t.Fatalf("MoveFile: %v", err)
	}

	got, _ := db.GetFileByID(f.ID)
	if !got.ParentID.Valid || got.ParentID.String != dir2.ID {
		t.Errorf("ParentID = %v, want %s", got.ParentID, dir2.ID)
	}
}

func TestRenameFile(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "frank")
	dir, _ := db.CreateFile("", u.ID, "Folder", true, 0, "", "")
	f, _ := db.CreateFile(dir.ID, u.ID, "old.txt", false, 50, "h", "text/plain")

	if err := db.MoveFile(f.ID, dir.ID, "new.txt"); err != nil {
		t.Fatalf("MoveFile (rename): %v", err)
	}
	got, _ := db.GetFileByID(f.ID)
	if got.Name != "new.txt" {
		t.Errorf("Name = %q, want new.txt", got.Name)
	}
}

func TestSoftDeleteFile(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "grace")
	parent, _ := db.CreateFile("", u.ID, "Docs", true, 0, "", "")
	f, _ := db.CreateFile(parent.ID, u.ID, "delete_me.txt", false, 10, "h", "text/plain")

	if err := db.SoftDeleteFile(f.ID); err != nil {
		t.Fatalf("SoftDeleteFile: %v", err)
	}

	// Should not appear in listings.
	children, _ := db.ListChildren(parent.ID)
	for _, child := range children {
		if child.ID == f.ID {
			t.Error("soft-deleted file still appears in ListChildren")
		}
	}

	// GetFileByID should still return it (with deleted_at set).
	got, err := db.GetFileByID(f.ID)
	if err != nil {
		t.Fatalf("GetFileByID after soft delete: %v", err)
	}
	if !got.DeletedAt.Valid {
		t.Error("expected deleted_at to be set")
	}
}

func TestUpdateFileContent(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "henry")
	f, _ := db.CreateFile("", u.ID, "data.bin", false, 100, "oldhash", "application/octet-stream")

	if err := db.UpdateFileContent(f.ID, "newhash", 200); err != nil {
		t.Fatalf("UpdateFileContent: %v", err)
	}
	got, _ := db.GetFileByID(f.ID)
	if got.ContentHash.String != "newhash" {
		t.Errorf("ContentHash = %q, want newhash", got.ContentHash.String)
	}
	if got.Size != 200 {
		t.Errorf("Size = %d, want 200", got.Size)
	}
}

func TestListChangedFiles(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "changefeed")

	// Create a file that will be the baseline — should NOT appear in results.
	old, _ := db.CreateFile("", u.ID, "old.txt", false, 10, "h1", "text/plain")

	// Sleep to ensure a clear timestamp boundary
	time.Sleep(50 * time.Millisecond)

	// Capture the cutoff AFTER the old file was created
	since := time.Now().UTC()

	// Sleep again to ensure the next files are strictly after the cutoff
	time.Sleep(50 * time.Millisecond)

	// Create a new file after the cutoff — should appear.
	recent, _ := db.CreateFile("", u.ID, "recent.txt", false, 20, "h2", "text/plain")

	// Create and soft-delete a file after the cutoff — should appear (deletion is a change).
	deleted, _ := db.CreateFile("", u.ID, "deleted.txt", false, 30, "h3", "text/plain")
	if err := db.SoftDeleteFile(deleted.ID); err != nil {
		t.Fatalf("SoftDeleteFile: %v", err)
	}

	changes, err := db.ListChangedFiles(since, u.ID)
	if err != nil {
		t.Fatalf("ListChangedFiles: %v", err)
	}

	// Build a map of returned IDs for easier lookup.
	ids := make(map[string]bool, len(changes))
	for _, f := range changes {
		ids[f.ID] = true
	}

	if ids[old.ID] {
		t.Errorf("old file (updated before since) should NOT appear in changes")
	}
	if !ids[recent.ID] {
		t.Errorf("recent file should appear in changes")
	}
	if !ids[deleted.ID] {
		t.Errorf("soft-deleted file should appear in changes")
	}

	// Verify that the deleted entry has DeletedAt set.
	for _, f := range changes {
		if f.ID == deleted.ID && !f.DeletedAt.Valid {
			t.Errorf("deleted file should have DeletedAt set in change feed")
		}
	}
}

func TestListChangedFiles_OtherOwnerExcluded(t *testing.T) {
	db := openTestDB(t)
	alice := mustCreateUser(t, db, "alice_cf")
	bob := mustCreateUser(t, db, "bob_cf")

	since := time.Now().Add(-time.Second)

	db.CreateFile("", alice.ID, "alices_file.txt", false, 10, "ha", "text/plain")
	db.CreateFile("", bob.ID, "bobs_file.txt", false, 10, "hb", "text/plain")

	changes, err := db.ListChangedFiles(since, alice.ID)
	if err != nil {
		t.Fatalf("ListChangedFiles: %v", err)
	}
	for _, f := range changes {
		if f.OwnerID != alice.ID {
			t.Errorf("change feed for alice returned file owned by %s", f.OwnerID)
		}
	}
}

func TestStorageUsedByUser(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "iris")
	dir, _ := db.CreateFile("", u.ID, "Docs", true, 0, "", "")
	db.CreateFile(dir.ID, u.ID, "a.txt", false, 500, "h1", "text/plain")
	db.CreateFile(dir.ID, u.ID, "b.txt", false, 300, "h2", "text/plain")
	// Directories should not count.
	// Deleted files should not count.
	f3, _ := db.CreateFile(dir.ID, u.ID, "deleted.txt", false, 1000, "h3", "text/plain")
	db.SoftDeleteFile(f3.ID)

	used, err := db.StorageUsedByUser(u.ID)
	if err != nil {
		t.Fatalf("StorageUsedByUser: %v", err)
	}
	if used != 800 {
		t.Errorf("StorageUsedByUser = %d, want 800", used)
	}
}
