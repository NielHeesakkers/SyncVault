package metadata

import (
	"path/filepath"
	"testing"
)

// openTestDB opens a temporary SQLite database for testing.
func openTestDB(t *testing.T) *DB {
	t.Helper()
	dir := t.TempDir()
	db, err := Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

var expectedTables = []string{
	"users",
	"files",
	"versions",
	"team_folders",
	"team_permissions",
	"devices",
	"activity_log",
	"share_links",
	"retention_policies",
	"sync_state",
	"sync_tasks",
}

func TestDB_AllTablesExist(t *testing.T) {
	db := openTestDB(t)

	for _, table := range expectedTables {
		var name string
		err := db.db.QueryRow(
			"SELECT name FROM sqlite_master WHERE type='table' AND name=?", table,
		).Scan(&name)
		if err != nil {
			t.Errorf("table %q not found: %v", table, err)
		}
	}
}

func TestDB_WALModeEnabled(t *testing.T) {
	db := openTestDB(t)

	var mode string
	if err := db.db.QueryRow("PRAGMA journal_mode;").Scan(&mode); err != nil {
		t.Fatalf("query journal_mode: %v", err)
	}
	if mode != "wal" {
		t.Errorf("journal_mode = %q, want %q", mode, "wal")
	}
}

func TestDB_ForeignKeysEnabled(t *testing.T) {
	db := openTestDB(t)

	var fk int
	if err := db.db.QueryRow("PRAGMA foreign_keys;").Scan(&fk); err != nil {
		t.Fatalf("query foreign_keys: %v", err)
	}
	if fk != 1 {
		t.Errorf("foreign_keys = %d, want 1", fk)
	}
}
