package metadata

import (
	"database/sql"
	_ "embed"
	"fmt"
	"strings"

	_ "modernc.org/sqlite"
)

//go:embed schema.sql
var schemaSQL string

// DB wraps a *sql.DB and provides access to the SyncVault metadata store.
type DB struct {
	db *sql.DB
}

// Open opens (or creates) the SQLite database at the given path, applies the schema,
// and configures WAL mode, a 5-second busy timeout, and foreign key support.
func Open(path string) (*DB, error) {
	rawDB, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("metadata: open db: %w", err)
	}

	// Single writer to prevent SQLITE_BUSY on WAL with multiple connections.
	rawDB.SetMaxOpenConns(1)

	// Configure pragmas.
	pragmas := []string{
		"PRAGMA journal_mode=WAL;",
		"PRAGMA busy_timeout=5000;",
		"PRAGMA foreign_keys=ON;",
	}
	for _, p := range pragmas {
		if _, err := rawDB.Exec(p); err != nil {
			rawDB.Close()
			return nil, fmt.Errorf("metadata: set pragma %q: %w", p, err)
		}
	}

	// Apply schema.
	if _, err := rawDB.Exec(schemaSQL); err != nil {
		rawDB.Close()
		return nil, fmt.Errorf("metadata: apply schema: %w", err)
	}

	// Run incremental migrations that are safe to re-apply on existing databases.
	migrations := []string{
		`ALTER TABLE files ADD COLUMN removed_locally INTEGER NOT NULL DEFAULT 0`,
	}
	for _, m := range migrations {
		if _, err := rawDB.Exec(m); err != nil {
			// Ignore "duplicate column name" errors — migration already applied.
			if !isDuplicateColumnError(err) {
				rawDB.Close()
				return nil, fmt.Errorf("metadata: migration %q: %w", m, err)
			}
		}
	}

	return &DB{db: rawDB}, nil
}

// isDuplicateColumnError returns true when SQLite reports that a column already exists.
func isDuplicateColumnError(err error) bool {
	if err == nil {
		return false
	}
	s := err.Error()
	return strings.Contains(s, "duplicate column name") || strings.Contains(s, "already exists")
}

// Close closes the underlying database connection.
func (d *DB) Close() error {
	return d.db.Close()
}
