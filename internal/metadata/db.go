package metadata

import (
	"database/sql"
	_ "embed"
	"fmt"
	"log"
	"strings"
	"time"

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
		`ALTER TABLE users ADD COLUMN token_invalidated_at TEXT`,
		`ALTER TABLE files ADD COLUMN change_rank INTEGER NOT NULL DEFAULT 0`,
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

	// Create indexes that may not exist yet (idempotent).
	if _, err := rawDB.Exec(`CREATE INDEX IF NOT EXISTS idx_files_change_rank ON files(change_rank)`); err != nil {
		rawDB.Close()
		return nil, fmt.Errorf("metadata: create change_rank index: %w", err)
	}

	// One-time migration: sync files.size with latest version size.
	// After this, CreateVersion keeps files.size in sync automatically.
	var needsSizeSync int
	rawDB.QueryRow(`SELECT COUNT(*) FROM files f WHERE f.is_dir = 0 AND f.size = 0 AND EXISTS (SELECT 1 FROM versions v WHERE v.file_id = f.id AND v.size > 0)`).Scan(&needsSizeSync)
	if needsSizeSync > 0 {
		rawDB.Exec(`UPDATE files SET size = (SELECT v.size FROM versions v WHERE v.file_id = files.id ORDER BY v.version_num DESC LIMIT 1), content_hash = (SELECT v.content_hash FROM versions v WHERE v.file_id = files.id ORDER BY v.version_num DESC LIMIT 1) WHERE is_dir = 0 AND size = 0 AND EXISTS (SELECT 1 FROM versions v WHERE v.file_id = files.id AND v.size > 0)`)
		log.Printf("metadata: synced files.size for %d files from versions table", needsSizeSync)
	}

	// Periodic WAL checkpoint to keep the WAL file small.
	go func() {
		ticker := time.NewTicker(5 * time.Minute)
		for range ticker.C {
			rawDB.Exec("PRAGMA wal_checkpoint(TRUNCATE)")
		}
	}()

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
