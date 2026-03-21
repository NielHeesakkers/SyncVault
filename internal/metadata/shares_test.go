package metadata

import (
	"errors"
	"testing"
	"time"
)

func TestCreateShareLink(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "sharetestuser")
	f, _ := db.CreateFile("", u.ID, "shared.txt", false, 100, "hash1", "text/plain")

	sl, err := db.CreateShareLink(f.ID, u.ID, "", nil, 0)
	if err != nil {
		t.Fatalf("CreateShareLink: %v", err)
	}
	if sl.ID == "" {
		t.Error("expected non-empty ID")
	}
	if sl.Token == "" {
		t.Error("expected non-empty Token")
	}
	if len(sl.Token) < 10 {
		t.Errorf("Token too short: %q", sl.Token)
	}
	if sl.FileID != f.ID {
		t.Errorf("FileID = %q, want %q", sl.FileID, f.ID)
	}
	if sl.CreatedBy != u.ID {
		t.Errorf("CreatedBy = %q, want %q", sl.CreatedBy, u.ID)
	}
	if sl.DownloadCount != 0 {
		t.Errorf("DownloadCount = %d, want 0", sl.DownloadCount)
	}
	if sl.PasswordHash != "" {
		t.Errorf("expected empty PasswordHash, got %q", sl.PasswordHash)
	}
	if sl.ExpiresAt != nil {
		t.Errorf("expected nil ExpiresAt, got %v", sl.ExpiresAt)
	}
	if sl.MaxDownloads != 0 {
		t.Errorf("MaxDownloads = %d, want 0", sl.MaxDownloads)
	}
}

func TestCreateShareLink_WithPassword(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "pwshareuser")
	f, _ := db.CreateFile("", u.ID, "secure.txt", false, 50, "hash2", "text/plain")

	sl, err := db.CreateShareLink(f.ID, u.ID, "$2a$bcrypthash", nil, 0)
	if err != nil {
		t.Fatalf("CreateShareLink with password: %v", err)
	}
	if sl.PasswordHash != "$2a$bcrypthash" {
		t.Errorf("PasswordHash = %q, want $2a$bcrypthash", sl.PasswordHash)
	}
}

func TestCreateShareLink_WithExpiration(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "expshareuser")
	f, _ := db.CreateFile("", u.ID, "expiring.txt", false, 50, "hash3", "text/plain")

	exp := time.Now().Add(24 * time.Hour).UTC().Truncate(time.Second)
	sl, err := db.CreateShareLink(f.ID, u.ID, "", &exp, 10)
	if err != nil {
		t.Fatalf("CreateShareLink with expiration: %v", err)
	}
	if sl.ExpiresAt == nil {
		t.Fatal("expected non-nil ExpiresAt")
	}
	if sl.ExpiresAt.Unix() != exp.Unix() {
		t.Errorf("ExpiresAt = %v, want %v", sl.ExpiresAt, exp)
	}
	if sl.MaxDownloads != 10 {
		t.Errorf("MaxDownloads = %d, want 10", sl.MaxDownloads)
	}
}

func TestGetShareLinkByToken(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "getsharetestuser")
	f, _ := db.CreateFile("", u.ID, "gettest.txt", false, 100, "hash4", "text/plain")

	created, _ := db.CreateShareLink(f.ID, u.ID, "", nil, 0)

	got, err := db.GetShareLinkByToken(created.Token)
	if err != nil {
		t.Fatalf("GetShareLinkByToken: %v", err)
	}
	if got.ID != created.ID {
		t.Errorf("ID = %q, want %q", got.ID, created.ID)
	}
	if got.Token != created.Token {
		t.Errorf("Token = %q, want %q", got.Token, created.Token)
	}
	if got.FileID != f.ID {
		t.Errorf("FileID = %q, want %q", got.FileID, f.ID)
	}
}

func TestGetShareLinkByToken_NotFound(t *testing.T) {
	db := openTestDB(t)
	_, err := db.GetShareLinkByToken("nonexistenttoken")
	if !errors.Is(err, ErrShareLinkNotFound) {
		t.Errorf("expected ErrShareLinkNotFound, got %v", err)
	}
}

func TestIncrementShareDownload(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "dlcountuser")
	f, _ := db.CreateFile("", u.ID, "download.txt", false, 100, "hash5", "text/plain")

	sl, _ := db.CreateShareLink(f.ID, u.ID, "", nil, 0)

	if err := db.IncrementShareDownload(sl.ID); err != nil {
		t.Fatalf("IncrementShareDownload: %v", err)
	}
	if err := db.IncrementShareDownload(sl.ID); err != nil {
		t.Fatalf("IncrementShareDownload (2nd): %v", err)
	}

	got, err := db.GetShareLinkByToken(sl.Token)
	if err != nil {
		t.Fatalf("GetShareLinkByToken: %v", err)
	}
	if got.DownloadCount != 2 {
		t.Errorf("DownloadCount = %d, want 2", got.DownloadCount)
	}
}

func TestDeleteShareLink(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "delshareuser")
	f, _ := db.CreateFile("", u.ID, "todelete.txt", false, 100, "hash6", "text/plain")

	sl, _ := db.CreateShareLink(f.ID, u.ID, "", nil, 0)

	if err := db.DeleteShareLink(sl.ID); err != nil {
		t.Fatalf("DeleteShareLink: %v", err)
	}

	_, err := db.GetShareLinkByToken(sl.Token)
	if !errors.Is(err, ErrShareLinkNotFound) {
		t.Errorf("expected ErrShareLinkNotFound after delete, got %v", err)
	}
}

func TestDeleteShareLink_NotFound(t *testing.T) {
	db := openTestDB(t)
	err := db.DeleteShareLink("nonexistentid")
	if !errors.Is(err, ErrShareLinkNotFound) {
		t.Errorf("expected ErrShareLinkNotFound, got %v", err)
	}
}

func TestListShareLinks(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "listshareuser")
	f, _ := db.CreateFile("", u.ID, "shared.txt", false, 100, "hash7", "text/plain")

	sl1, _ := db.CreateShareLink(f.ID, u.ID, "", nil, 0)
	sl2, _ := db.CreateShareLink(f.ID, u.ID, "pwdhash", nil, 5)

	links, err := db.ListShareLinks(f.ID)
	if err != nil {
		t.Fatalf("ListShareLinks: %v", err)
	}
	if len(links) != 2 {
		t.Fatalf("len(links) = %d, want 2", len(links))
	}

	// Newest first — sl2 was created after sl1.
	if links[0].ID != sl2.ID {
		t.Errorf("links[0].ID = %q, want %q (newest first)", links[0].ID, sl2.ID)
	}
	if links[1].ID != sl1.ID {
		t.Errorf("links[1].ID = %q, want %q", links[1].ID, sl1.ID)
	}
}

func TestListShareLinks_EmptyForOtherFile(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "listemptyuser")
	f1, _ := db.CreateFile("", u.ID, "file1.txt", false, 100, "h1", "text/plain")
	f2, _ := db.CreateFile("", u.ID, "file2.txt", false, 100, "h2", "text/plain")

	db.CreateShareLink(f1.ID, u.ID, "", nil, 0)

	links, err := db.ListShareLinks(f2.ID)
	if err != nil {
		t.Fatalf("ListShareLinks: %v", err)
	}
	if len(links) != 0 {
		t.Errorf("expected empty list for f2, got %d items", len(links))
	}
}
