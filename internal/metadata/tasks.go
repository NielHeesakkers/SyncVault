package metadata

import (
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

// SyncTask represents a sync, backup, or on-demand task owned by a user.
type SyncTask struct {
	ID        string
	UserID    string
	FolderID  string
	Name      string
	Type      string
	LocalPath string
	Status    string
	CreatedAt time.Time
}

// ErrTaskNotFound is returned when a sync task cannot be found.
var ErrTaskNotFound = errors.New("metadata: sync task not found")

// ErrDuplicateTask is returned when a task with the same name already exists for the user.
var ErrDuplicateTask = errors.New("metadata: duplicate task name for user")

// ErrRootFolderNotFound is returned when a user's root folder cannot be found.
var ErrRootFolderNotFound = errors.New("metadata: user root folder not found")

// GetUserRootFolder finds the root folder for the user — a folder with no parent,
// owned by the user, that is a directory and has not been deleted.
func (d *DB) GetUserRootFolder(userID string) (*File, error) {
	row := d.db.QueryRow(
		`SELECT id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type, created_at, updated_at, deleted_at, removed_locally, folder_size
		 FROM files
		 WHERE owner_id = ? AND parent_id IS NULL AND is_dir = 1 AND deleted_at IS NULL
		 ORDER BY created_at ASC
		 LIMIT 1`,
		userID,
	)
	f, err := scanFile(row)
	if errors.Is(err, ErrFileNotFound) {
		return nil, ErrRootFolderNotFound
	}
	return f, err
}

// CreateSyncTask inserts a new sync task record and returns it.
func (d *DB) CreateSyncTask(userID, folderID, name, taskType, localPath string) (*SyncTask, error) {
	// For ondemand tasks, replace any existing one (user wants to start fresh).
	if taskType == "ondemand" {
		d.db.Exec(
			`DELETE FROM sync_tasks WHERE user_id = ? AND type = 'ondemand'`,
			userID,
		)
	}

	t := &SyncTask{
		ID:        uuid.New().String(),
		UserID:    userID,
		FolderID:  folderID,
		Name:      name,
		Type:      taskType,
		LocalPath: localPath,
		Status:    "active",
		CreatedAt: time.Now().UTC(),
	}

	var localPathVal interface{}
	if localPath != "" {
		localPathVal = localPath
	}

	_, err := d.db.Exec(
		`INSERT INTO sync_tasks (id, user_id, folder_id, name, type, local_path, status, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		t.ID, t.UserID, t.FolderID, t.Name, t.Type, localPathVal, t.Status,
		t.CreatedAt.Format(time.RFC3339Nano),
	)
	if err != nil {
		if isSQLiteConstraint(err) {
			return nil, ErrDuplicateTask
		}
		return nil, fmt.Errorf("metadata: create sync task: %w", err)
	}
	return t, nil
}

// ListSyncTasks returns all sync tasks for the given user, ordered by creation time.
func (d *DB) ListSyncTasks(userID string) ([]SyncTask, error) {
	rows, err := d.db.Query(
		`SELECT id, user_id, folder_id, name, type, local_path, status, created_at
		 FROM sync_tasks WHERE user_id = ? ORDER BY created_at ASC`,
		userID,
	)
	if err != nil {
		return nil, fmt.Errorf("metadata: list sync tasks: %w", err)
	}
	defer rows.Close()

	var tasks []SyncTask
	for rows.Next() {
		t, err := scanSyncTaskRow(rows)
		if err != nil {
			return nil, err
		}
		tasks = append(tasks, *t)
	}
	return tasks, rows.Err()
}

// GetSyncTask returns the sync task with the given ID.
func (d *DB) GetSyncTask(id string) (*SyncTask, error) {
	row := d.db.QueryRow(
		`SELECT id, user_id, folder_id, name, type, local_path, status, created_at
		 FROM sync_tasks WHERE id = ?`,
		id,
	)
	t, err := scanSyncTask(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrTaskNotFound
	}
	return t, err
}

// DeleteSyncTaskByName removes any sync task with the given name for the user. No error if not found.
func (d *DB) DeleteSyncTaskByName(userID, name string) {
	d.db.Exec(`DELETE FROM sync_tasks WHERE user_id = ? AND name = ?`, userID, name)
}

// DeleteSyncTask removes the sync task with the given ID.
func (d *DB) DeleteSyncTask(id string) error {
	res, err := d.db.Exec(`DELETE FROM sync_tasks WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("metadata: delete sync task: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrTaskNotFound
	}
	return nil
}

// scanSyncTask scans a single SyncTask from a *sql.Row.
func scanSyncTask(row *sql.Row) (*SyncTask, error) {
	var t SyncTask
	var localPath sql.NullString
	var createdAt string
	err := row.Scan(&t.ID, &t.UserID, &t.FolderID, &t.Name, &t.Type, &localPath, &t.Status, &createdAt)
	if err != nil {
		return nil, fmt.Errorf("metadata: scan sync task: %w", err)
	}
	if localPath.Valid {
		t.LocalPath = localPath.String
	}
	t.CreatedAt, _ = time.Parse(time.RFC3339Nano, createdAt)
	return &t, nil
}

// scanSyncTaskRow scans a single SyncTask from *sql.Rows.
func scanSyncTaskRow(rows *sql.Rows) (*SyncTask, error) {
	var t SyncTask
	var localPath sql.NullString
	var createdAt string
	err := rows.Scan(&t.ID, &t.UserID, &t.FolderID, &t.Name, &t.Type, &localPath, &t.Status, &createdAt)
	if err != nil {
		return nil, fmt.Errorf("metadata: scan sync task row: %w", err)
	}
	if localPath.Valid {
		t.LocalPath = localPath.String
	}
	t.CreatedAt, _ = time.Parse(time.RFC3339Nano, createdAt)
	return &t, nil
}
