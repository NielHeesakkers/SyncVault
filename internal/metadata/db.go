package metadata

import (
	"database/sql"
	_ "embed"
	"fmt"

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

	return &DB{db: rawDB}, nil
}

// Close closes the underlying database connection.
func (d *DB) Close() error {
	return d.db.Close()
}
