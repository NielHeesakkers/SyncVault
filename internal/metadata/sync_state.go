package metadata

import (
	"fmt"

	"github.com/google/uuid"
)

// SyncState represents the known sync state of a single file for a given user, device, and task.
type SyncState struct {
	FilePath    string
	ContentHash string
	SyncedAt    string
}

// SaveSyncStates upserts all provided sync states for the given user, device, and task.
func (d *DB) SaveSyncStates(userID, deviceID, taskName string, states []SyncState) error {
	tx, err := d.db.Begin()
	if err != nil {
		return fmt.Errorf("metadata: save sync states begin tx: %w", err)
	}
	defer tx.Rollback()

	stmt, err := tx.Prepare(`
		INSERT INTO sync_states (id, user_id, device_id, task_name, file_path, content_hash, synced_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(user_id, device_id, task_name, file_path) DO UPDATE SET
			content_hash = excluded.content_hash,
			synced_at    = excluded.synced_at
	`)
	if err != nil {
		return fmt.Errorf("metadata: save sync states prepare: %w", err)
	}
	defer stmt.Close()

	for _, s := range states {
		if _, err := stmt.Exec(uuid.New().String(), userID, deviceID, taskName, s.FilePath, s.ContentHash, s.SyncedAt); err != nil {
			return fmt.Errorf("metadata: save sync state %q: %w", s.FilePath, err)
		}
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("metadata: save sync states commit: %w", err)
	}
	return nil
}

// GetSyncStates returns all sync states for the given user, device, and task.
func (d *DB) GetSyncStates(userID, deviceID, taskName string) ([]SyncState, error) {
	rows, err := d.db.Query(
		`SELECT file_path, content_hash, synced_at
		 FROM sync_states
		 WHERE user_id = ? AND device_id = ? AND task_name = ?
		 ORDER BY file_path`,
		userID, deviceID, taskName,
	)
	if err != nil {
		return nil, fmt.Errorf("metadata: get sync states: %w", err)
	}
	defer rows.Close()

	var states []SyncState
	for rows.Next() {
		var s SyncState
		if err := rows.Scan(&s.FilePath, &s.ContentHash, &s.SyncedAt); err != nil {
			return nil, fmt.Errorf("metadata: scan sync state: %w", err)
		}
		states = append(states, s)
	}
	return states, rows.Err()
}

// DeleteSyncStates removes all sync states for the given user, device, and task.
func (d *DB) DeleteSyncStates(userID, deviceID, taskName string) error {
	_, err := d.db.Exec(
		`DELETE FROM sync_states WHERE user_id = ? AND device_id = ? AND task_name = ?`,
		userID, deviceID, taskName,
	)
	if err != nil {
		return fmt.Errorf("metadata: delete sync states: %w", err)
	}
	return nil
}
