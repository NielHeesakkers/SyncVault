package metadata

import (
	"errors"
	"testing"
)

func TestGetUserRootFolder(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "roottest")

	// No root folder yet.
	_, err := db.GetUserRootFolder(u.ID)
	if !errors.Is(err, ErrRootFolderNotFound) {
		t.Fatalf("expected ErrRootFolderNotFound before creation, got %v", err)
	}

	// Create the root folder.
	root, err := db.CreateFile("", u.ID, u.Username, true, 0, "", "")
	if err != nil {
		t.Fatalf("CreateFile root: %v", err)
	}

	got, err := db.GetUserRootFolder(u.ID)
	if err != nil {
		t.Fatalf("GetUserRootFolder: %v", err)
	}
	if got.ID != root.ID {
		t.Errorf("root folder ID = %q, want %q", got.ID, root.ID)
	}
	if !got.IsDir {
		t.Error("expected IsDir=true for root folder")
	}
	if got.ParentID.Valid {
		t.Error("expected NULL parent_id for root folder")
	}
}

func TestGetUserRootFolder_IgnoresNonRoot(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "nonroot")

	// Create root folder, then a child folder.
	root, _ := db.CreateFile("", u.ID, u.Username, true, 0, "", "")
	_, _ = db.CreateFile(root.ID, u.ID, "Docs", true, 0, "", "")

	got, err := db.GetUserRootFolder(u.ID)
	if err != nil {
		t.Fatalf("GetUserRootFolder: %v", err)
	}
	if got.ID != root.ID {
		t.Errorf("expected root folder, got %q", got.Name)
	}
}

func TestCreateSyncTask(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "taskuser")
	root, _ := db.CreateFile("", u.ID, u.Username, true, 0, "", "")
	subFolder, _ := db.CreateFile(root.ID, u.ID, "Sync-Documents", true, 0, "", "")

	task, err := db.CreateSyncTask(u.ID, subFolder.ID, "Documents", "sync", "/Users/taskuser/Documents")
	if err != nil {
		t.Fatalf("CreateSyncTask: %v", err)
	}
	if task.ID == "" {
		t.Error("expected non-empty task ID")
	}
	if task.Name != "Documents" {
		t.Errorf("Name = %q, want Documents", task.Name)
	}
	if task.Type != "sync" {
		t.Errorf("Type = %q, want sync", task.Type)
	}
	if task.FolderID != subFolder.ID {
		t.Errorf("FolderID = %q, want %q", task.FolderID, subFolder.ID)
	}
	if task.LocalPath != "/Users/taskuser/Documents" {
		t.Errorf("LocalPath = %q, want /Users/taskuser/Documents", task.LocalPath)
	}
	if task.Status != "active" {
		t.Errorf("Status = %q, want active", task.Status)
	}
}

func TestCreateSyncTask_Duplicate(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "dupuser")
	root, _ := db.CreateFile("", u.ID, u.Username, true, 0, "", "")
	f1, _ := db.CreateFile(root.ID, u.ID, "Sync-Docs", true, 0, "", "")
	f2, _ := db.CreateFile(root.ID, u.ID, "Sync-Docs2", true, 0, "", "")

	_, err := db.CreateSyncTask(u.ID, f1.ID, "Docs", "sync", "")
	if err != nil {
		t.Fatalf("first CreateSyncTask: %v", err)
	}
	_, err = db.CreateSyncTask(u.ID, f2.ID, "Docs", "sync", "")
	if !errors.Is(err, ErrDuplicateTask) {
		t.Errorf("expected ErrDuplicateTask for duplicate name, got %v", err)
	}
}

func TestCreateSyncTask_OnDemandLimitedToOne(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "ondemanduser")
	root, _ := db.CreateFile("", u.ID, u.Username, true, 0, "", "")
	f1, _ := db.CreateFile(root.ID, u.ID, "OnDemand", true, 0, "", "")
	f2, _ := db.CreateFile(root.ID, u.ID, "OnDemand2", true, 0, "", "")

	_, err := db.CreateSyncTask(u.ID, f1.ID, "OnDemand", "ondemand", "")
	if err != nil {
		t.Fatalf("first ondemand task: %v", err)
	}

	_, err = db.CreateSyncTask(u.ID, f2.ID, "OnDemand", "ondemand", "")
	if !errors.Is(err, ErrOnDemandExists) {
		t.Errorf("expected ErrOnDemandExists for second ondemand task, got %v", err)
	}
}

func TestListSyncTasks(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "listuser")
	root, _ := db.CreateFile("", u.ID, u.Username, true, 0, "", "")
	f1, _ := db.CreateFile(root.ID, u.ID, "Sync-A", true, 0, "", "")
	f2, _ := db.CreateFile(root.ID, u.ID, "Backup-B", true, 0, "", "")

	db.CreateSyncTask(u.ID, f1.ID, "A", "sync", "")
	db.CreateSyncTask(u.ID, f2.ID, "B", "backup", "")

	tasks, err := db.ListSyncTasks(u.ID)
	if err != nil {
		t.Fatalf("ListSyncTasks: %v", err)
	}
	if len(tasks) != 2 {
		t.Errorf("len(tasks) = %d, want 2", len(tasks))
	}
}

func TestGetSyncTask(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "gettaskuser")
	root, _ := db.CreateFile("", u.ID, u.Username, true, 0, "", "")
	f, _ := db.CreateFile(root.ID, u.ID, "Sync-X", true, 0, "", "")

	created, _ := db.CreateSyncTask(u.ID, f.ID, "X", "sync", "/path/x")

	got, err := db.GetSyncTask(created.ID)
	if err != nil {
		t.Fatalf("GetSyncTask: %v", err)
	}
	if got.ID != created.ID {
		t.Errorf("ID = %q, want %q", got.ID, created.ID)
	}
	if got.LocalPath != "/path/x" {
		t.Errorf("LocalPath = %q, want /path/x", got.LocalPath)
	}
}

func TestGetSyncTask_NotFound(t *testing.T) {
	db := openTestDB(t)
	_, err := db.GetSyncTask("nonexistent")
	if !errors.Is(err, ErrTaskNotFound) {
		t.Errorf("expected ErrTaskNotFound, got %v", err)
	}
}

func TestDeleteSyncTask(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "deltaskuser")
	root, _ := db.CreateFile("", u.ID, u.Username, true, 0, "", "")
	f, _ := db.CreateFile(root.ID, u.ID, "Sync-Del", true, 0, "", "")

	task, _ := db.CreateSyncTask(u.ID, f.ID, "Del", "sync", "")

	if err := db.DeleteSyncTask(task.ID); err != nil {
		t.Fatalf("DeleteSyncTask: %v", err)
	}

	// Should be gone.
	_, err := db.GetSyncTask(task.ID)
	if !errors.Is(err, ErrTaskNotFound) {
		t.Errorf("expected ErrTaskNotFound after delete, got %v", err)
	}
}

func TestDeleteSyncTask_NotFound(t *testing.T) {
	db := openTestDB(t)
	err := db.DeleteSyncTask("nonexistent")
	if !errors.Is(err, ErrTaskNotFound) {
		t.Errorf("expected ErrTaskNotFound, got %v", err)
	}
}
