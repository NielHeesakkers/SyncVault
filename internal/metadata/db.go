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

	// Allow multiple readers + 1 writer for WAL mode concurrency.
	rawDB.SetMaxOpenConns(8)
	rawDB.SetMaxIdleConns(4)

	// Configure pragmas for maximum performance in WAL mode.
	pragmas := []string{
		"PRAGMA journal_mode=WAL;",
		"PRAGMA busy_timeout=5000;",
		"PRAGMA foreign_keys=ON;",
		"PRAGMA synchronous=NORMAL;",    // Safe in WAL mode, much faster writes
		"PRAGMA cache_size=-20000;",     // 20 MB page cache (negative = KB)
		"PRAGMA temp_store=MEMORY;",     // Temp tables in RAM
		"PRAGMA mmap_size=268435456;",   // 256 MB memory-mapped I/O
		"PRAGMA wal_autocheckpoint=1000;", // Checkpoint after 1000 pages
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
		`ALTER TABLE files ADD COLUMN folder_size INTEGER NOT NULL DEFAULT 0`,
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

	// Background migration: sync files.size with latest version size.
	// Runs async so it doesn't block server startup or requests.
	go func() {
		time.Sleep(5 * time.Second) // Brief delay to let server start handling requests

		// Only sync file sizes if there are mismatches (rare after initial migration)
		var needsSizeSync int
		rawDB.QueryRow(`SELECT EXISTS(SELECT 1 FROM files WHERE is_dir = 0 AND size = 0 AND id IN (SELECT file_id FROM versions WHERE size > 0 LIMIT 1))`).Scan(&needsSizeSync)
		if needsSizeSync > 0 {
			log.Printf("metadata: syncing files.size in background...")
			rawDB.Exec(`UPDATE files SET size = (SELECT v.size FROM versions v WHERE v.file_id = files.id ORDER BY v.version_num DESC LIMIT 1), content_hash = (SELECT v.content_hash FROM versions v WHERE v.file_id = files.id ORDER BY v.version_num DESC LIMIT 1) WHERE is_dir = 0 AND size = 0 AND id IN (SELECT DISTINCT file_id FROM versions WHERE size > 0)`)
			log.Printf("metadata: files.size sync complete")
		}

		// Backfill folder_size only if needed (check for zero-size directories with children)
		var needsFolderFix int
		rawDB.QueryRow(`SELECT EXISTS(SELECT 1 FROM files WHERE is_dir = 1 AND folder_size = 0 AND deleted_at IS NULL AND id IN (SELECT parent_id FROM files WHERE deleted_at IS NULL AND (size > 0 OR folder_size > 0) LIMIT 1))`).Scan(&needsFolderFix)
		if needsFolderFix > 0 {
			log.Printf("metadata: folder_size backfill starting...")
			for round := 0; round < 15; round++ {
				res, _ := rawDB.Exec(`
					UPDATE files SET folder_size = (
						SELECT COALESCE(SUM(
							CASE WHEN c.is_dir = 1 THEN c.folder_size ELSE c.size END
						), 0)
						FROM files c WHERE c.parent_id = files.id AND c.deleted_at IS NULL
					)
					WHERE is_dir = 1 AND deleted_at IS NULL
				`)
				if n, _ := res.RowsAffected(); n == 0 {
					break // No more changes
				}
			}
			log.Printf("metadata: folder_size backfill complete")
		}
	}()

	// Smart Retention: apply default policies to existing tasks and enforce periodically.
	go func() {
		time.Sleep(1 * time.Minute) // Wait for server to be fully ready.
		d := &DB{db: rawDB}

		// Apply default retention to existing tasks that have no policy.
		_, err := rawDB.Exec(`INSERT OR IGNORE INTO retention_policies (id, sync_task_id, daily_days, weekly_weeks, monthly_months, max_versions)
			SELECT hex(randomblob(16)), id, 90, 24, 12, 10 FROM sync_tasks
			WHERE id NOT IN (SELECT sync_task_id FROM retention_policies WHERE sync_task_id IS NOT NULL)`)
		if err != nil {
			log.Printf("metadata: apply default retention policies: %v", err)
		} else {
			log.Printf("metadata: default retention policies applied to existing tasks")
		}

		// Run enforcement immediately, then every 6 hours.
		d.EnforceAllRetentionPolicies()
		d.CleanupOldTrash(30)
		log.Printf("metadata: initial retention enforcement and trash cleanup complete")

		ticker := time.NewTicker(6 * time.Hour)
		for range ticker.C {
			d.EnforceAllRetentionPolicies()
			d.CleanupOldTrash(30)
			log.Printf("metadata: periodic retention enforcement and trash cleanup complete")
		}
	}()

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
