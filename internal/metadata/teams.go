package metadata

import (
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

// TeamFolder represents a shared team folder.
type TeamFolder struct {
	ID        string
	Name      string
	CreatedAt time.Time
}

// TeamPermission represents a user's permission on a team folder.
type TeamPermission struct {
	ID           string
	TeamFolderID string
	UserID       string
	Permission   string // "read" or "write"
}

// ErrTeamFolderNotFound is returned when a team folder cannot be found.
var ErrTeamFolderNotFound = errors.New("metadata: team folder not found")

// ErrDuplicateTeamFolder is returned when creating a team folder with a conflicting name.
var ErrDuplicateTeamFolder = errors.New("metadata: duplicate team folder name")

// ErrPermissionNotFound is returned when a permission record cannot be found.
var ErrPermissionNotFound = errors.New("metadata: permission not found")

// CreateTeamFolder creates a new team folder and returns it.
func (d *DB) CreateTeamFolder(name string) (*TeamFolder, error) {
	now := time.Now().UTC()
	tf := &TeamFolder{
		ID:        uuid.New().String(),
		Name:      name,
		CreatedAt: now,
	}
	_, err := d.db.Exec(
		`INSERT INTO team_folders (id, name, created_at) VALUES (?, ?, ?)`,
		tf.ID, tf.Name, tf.CreatedAt.Format(time.RFC3339Nano),
	)
	if err != nil {
		if isSQLiteConstraint(err) {
			return nil, ErrDuplicateTeamFolder
		}
		return nil, fmt.Errorf("metadata: create team folder: %w", err)
	}
	return tf, nil
}

// ListTeamFolders returns all team folders ordered by name.
func (d *DB) ListTeamFolders() ([]TeamFolder, error) {
	rows, err := d.db.Query(
		`SELECT id, name, created_at FROM team_folders ORDER BY name`,
	)
	if err != nil {
		return nil, fmt.Errorf("metadata: list team folders: %w", err)
	}
	defer rows.Close()

	var folders []TeamFolder
	for rows.Next() {
		var tf TeamFolder
		var createdAt string
		if err := rows.Scan(&tf.ID, &tf.Name, &createdAt); err != nil {
			return nil, fmt.Errorf("metadata: scan team folder: %w", err)
		}
		tf.CreatedAt, _ = time.Parse(time.RFC3339Nano, createdAt)
		folders = append(folders, tf)
	}
	return folders, rows.Err()
}

// DeleteTeamFolder removes a team folder by ID.
func (d *DB) DeleteTeamFolder(id string) error {
	res, err := d.db.Exec(`DELETE FROM team_folders WHERE id=?`, id)
	if err != nil {
		return fmt.Errorf("metadata: delete team folder: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrTeamFolderNotFound
	}
	return nil
}

// SetTeamPermission upserts a permission record for a user on a team folder.
func (d *DB) SetTeamPermission(teamFolderID, userID, permission string) error {
	id := uuid.New().String()
	_, err := d.db.Exec(
		`INSERT INTO team_permissions (id, team_folder_id, user_id, permission)
		 VALUES (?, ?, ?, ?)
		 ON CONFLICT(team_folder_id, user_id) DO UPDATE SET permission=excluded.permission`,
		id, teamFolderID, userID, permission,
	)
	if err != nil {
		return fmt.Errorf("metadata: set team permission: %w", err)
	}
	return nil
}

// GetTeamPermission returns the permission string for a user on a team folder.
func (d *DB) GetTeamPermission(teamFolderID, userID string) (string, error) {
	var perm string
	err := d.db.QueryRow(
		`SELECT permission FROM team_permissions WHERE team_folder_id=? AND user_id=?`,
		teamFolderID, userID,
	).Scan(&perm)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrPermissionNotFound
	}
	if err != nil {
		return "", fmt.Errorf("metadata: get team permission: %w", err)
	}
	return perm, nil
}

// ListTeamPermissions returns all permissions for a team folder.
func (d *DB) ListTeamPermissions(teamFolderID string) ([]TeamPermission, error) {
	rows, err := d.db.Query(
		`SELECT id, team_folder_id, user_id, permission FROM team_permissions
		 WHERE team_folder_id=? ORDER BY user_id`,
		teamFolderID,
	)
	if err != nil {
		return nil, fmt.Errorf("metadata: list team permissions: %w", err)
	}
	defer rows.Close()

	var perms []TeamPermission
	for rows.Next() {
		var p TeamPermission
		if err := rows.Scan(&p.ID, &p.TeamFolderID, &p.UserID, &p.Permission); err != nil {
			return nil, fmt.Errorf("metadata: scan team permission: %w", err)
		}
		perms = append(perms, p)
	}
	return perms, rows.Err()
}

// ListUserTeamFolders returns all team folders that a user has any permission on.
func (d *DB) ListUserTeamFolders(userID string) ([]TeamFolder, error) {
	rows, err := d.db.Query(
		`SELECT tf.id, tf.name, tf.created_at
		 FROM team_folders tf
		 JOIN team_permissions tp ON tp.team_folder_id = tf.id
		 WHERE tp.user_id = ?
		 ORDER BY tf.name`,
		userID,
	)
	if err != nil {
		return nil, fmt.Errorf("metadata: list user team folders: %w", err)
	}
	defer rows.Close()

	var folders []TeamFolder
	for rows.Next() {
		var tf TeamFolder
		var createdAt string
		if err := rows.Scan(&tf.ID, &tf.Name, &createdAt); err != nil {
			return nil, fmt.Errorf("metadata: scan team folder for user: %w", err)
		}
		tf.CreatedAt, _ = time.Parse(time.RFC3339Nano, createdAt)
		folders = append(folders, tf)
	}
	return folders, rows.Err()
}

// RemoveTeamPermission deletes a specific user's permission from a team folder.
func (d *DB) RemoveTeamPermission(teamFolderID, userID string) error {
	res, err := d.db.Exec(
		`DELETE FROM team_permissions WHERE team_folder_id=? AND user_id=?`,
		teamFolderID, userID,
	)
	if err != nil {
		return fmt.Errorf("metadata: remove team permission: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrPermissionNotFound
	}
	return nil
}
