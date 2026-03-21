package metadata

import (
	"errors"
	"testing"
)

func TestCreateTeamFolder(t *testing.T) {
	db := openTestDB(t)
	tf, err := db.CreateTeamFolder("Engineering")
	if err != nil {
		t.Fatalf("CreateTeamFolder: %v", err)
	}
	if tf.ID == "" {
		t.Error("expected non-empty ID")
	}
	if tf.Name != "Engineering" {
		t.Errorf("Name = %q, want Engineering", tf.Name)
	}
}

func TestCreateTeamFolder_DuplicateName(t *testing.T) {
	db := openTestDB(t)
	if _, err := db.CreateTeamFolder("Design"); err != nil {
		t.Fatal(err)
	}
	_, err := db.CreateTeamFolder("Design")
	if !errors.Is(err, ErrDuplicateTeamFolder) {
		t.Errorf("expected ErrDuplicateTeamFolder, got %v", err)
	}
}

func TestListTeamFolders(t *testing.T) {
	db := openTestDB(t)
	db.CreateTeamFolder("Bravo")
	db.CreateTeamFolder("Alpha")
	db.CreateTeamFolder("Charlie")

	folders, err := db.ListTeamFolders()
	if err != nil {
		t.Fatalf("ListTeamFolders: %v", err)
	}
	if len(folders) != 3 {
		t.Fatalf("len(folders) = %d, want 3", len(folders))
	}
	// Should be sorted by name.
	if folders[0].Name != "Alpha" {
		t.Errorf("folders[0].Name = %q, want Alpha", folders[0].Name)
	}
	if folders[1].Name != "Bravo" {
		t.Errorf("folders[1].Name = %q, want Bravo", folders[1].Name)
	}
}

func TestSetTeamPermission(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "perm_alice")
	tf, _ := db.CreateTeamFolder("SharedDocs")

	if err := db.SetTeamPermission(tf.ID, u.ID, "read"); err != nil {
		t.Fatalf("SetTeamPermission: %v", err)
	}
	perm, err := db.GetTeamPermission(tf.ID, u.ID)
	if err != nil {
		t.Fatalf("GetTeamPermission: %v", err)
	}
	if perm != "read" {
		t.Errorf("permission = %q, want read", perm)
	}
}

func TestUpdateTeamPermission(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "perm_bob")
	tf, _ := db.CreateTeamFolder("TeamB")

	db.SetTeamPermission(tf.ID, u.ID, "read")
	// Upsert: upgrade to write.
	if err := db.SetTeamPermission(tf.ID, u.ID, "write"); err != nil {
		t.Fatalf("SetTeamPermission (update): %v", err)
	}
	perm, _ := db.GetTeamPermission(tf.ID, u.ID)
	if perm != "write" {
		t.Errorf("permission = %q, want write", perm)
	}
}

func TestListTeamPermissions(t *testing.T) {
	db := openTestDB(t)
	u1 := mustCreateUser(t, db, "perm_carol")
	u2 := mustCreateUser(t, db, "perm_dave")
	tf, _ := db.CreateTeamFolder("MultiPerm")

	db.SetTeamPermission(tf.ID, u1.ID, "read")
	db.SetTeamPermission(tf.ID, u2.ID, "write")

	perms, err := db.ListTeamPermissions(tf.ID)
	if err != nil {
		t.Fatalf("ListTeamPermissions: %v", err)
	}
	if len(perms) != 2 {
		t.Fatalf("len(perms) = %d, want 2", len(perms))
	}
}

func TestListUserTeamFolders(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "perm_eve")
	tf1, _ := db.CreateTeamFolder("FolderX")
	tf2, _ := db.CreateTeamFolder("FolderY")
	_, _ = tf1, tf2
	db.SetTeamPermission(tf1.ID, u.ID, "read")
	db.SetTeamPermission(tf2.ID, u.ID, "write")

	folders, err := db.ListUserTeamFolders(u.ID)
	if err != nil {
		t.Fatalf("ListUserTeamFolders: %v", err)
	}
	if len(folders) != 2 {
		t.Fatalf("len(folders) = %d, want 2", len(folders))
	}
}

func TestRemoveTeamPermission(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "perm_frank")
	tf, _ := db.CreateTeamFolder("TempFolder")

	db.SetTeamPermission(tf.ID, u.ID, "read")
	if err := db.RemoveTeamPermission(tf.ID, u.ID); err != nil {
		t.Fatalf("RemoveTeamPermission: %v", err)
	}
	_, err := db.GetTeamPermission(tf.ID, u.ID)
	if !errors.Is(err, ErrPermissionNotFound) {
		t.Errorf("expected ErrPermissionNotFound after remove, got %v", err)
	}
}

func TestRemoveTeamPermission_NotFound(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "perm_grace")
	tf, _ := db.CreateTeamFolder("NoPermFolder")
	err := db.RemoveTeamPermission(tf.ID, u.ID)
	if !errors.Is(err, ErrPermissionNotFound) {
		t.Errorf("expected ErrPermissionNotFound, got %v", err)
	}
}

func TestDeleteTeamFolder(t *testing.T) {
	db := openTestDB(t)
	tf, _ := db.CreateTeamFolder("ToDelete")
	if err := db.DeleteTeamFolder(tf.ID); err != nil {
		t.Fatalf("DeleteTeamFolder: %v", err)
	}
	folders, _ := db.ListTeamFolders()
	for _, f := range folders {
		if f.ID == tf.ID {
			t.Error("deleted team folder still appears in list")
		}
	}
}

func TestDeleteTeamFolder_NotFound(t *testing.T) {
	db := openTestDB(t)
	err := db.DeleteTeamFolder("nonexistent")
	if !errors.Is(err, ErrTeamFolderNotFound) {
		t.Errorf("expected ErrTeamFolderNotFound, got %v", err)
	}
}

func TestGetTeamPermission_NotFound(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "perm_henry")
	tf, _ := db.CreateTeamFolder("EmptyFolder")
	_, err := db.GetTeamPermission(tf.ID, u.ID)
	if !errors.Is(err, ErrPermissionNotFound) {
		t.Errorf("expected ErrPermissionNotFound, got %v", err)
	}
}
