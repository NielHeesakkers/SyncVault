package metadata

import (
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

// File represents a file or directory in the SyncVault metadata store.
type File struct {
	ID          string
	ParentID    sql.NullString
	OwnerID     string
	Name        string
	IsDir       bool
	Size        int64
	ContentHash sql.NullString
	MimeType    sql.NullString
	CreatedAt   time.Time
	UpdatedAt   time.Time
	DeletedAt   sql.NullString
}

// ErrFileNotFound is returned when a file cannot be found.
var ErrFileNotFound = errors.New("metadata: file not found")

// ErrDuplicateFile is returned when creating a file with a conflicting name in the same parent.
var ErrDuplicateFile = errors.New("metadata: duplicate file name in parent")

// CreateFile inserts a new file or directory record.
func (d *DB) CreateFile(parentID, ownerID, name string, isDir bool, size int64, contentHash, mimeType string) (*File, error) {
	now := time.Now().UTC()
	f := &File{
		ID:      uuid.New().String(),
		OwnerID: ownerID,
		Name:    name,
		IsDir:   isDir,
		Size:    size,
		CreatedAt: now,
		UpdatedAt: now,
	}

	if parentID != "" {
		f.ParentID = sql.NullString{String: parentID, Valid: true}
	}
	if contentHash != "" {
		f.ContentHash = sql.NullString{String: contentHash, Valid: true}
	}
	if mimeType != "" {
		f.MimeType = sql.NullString{String: mimeType, Valid: true}
	}

	isDirInt := 0
	if isDir {
		isDirInt = 1
	}

	_, err := d.db.Exec(
		`INSERT INTO files (id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type, created_at, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		f.ID,
		nullStringVal(f.ParentID),
		f.OwnerID,
		f.Name,
		isDirInt,
		f.Size,
		nullStringVal(f.ContentHash),
		nullStringVal(f.MimeType),
		f.CreatedAt.Format(time.RFC3339Nano),
		f.UpdatedAt.Format(time.RFC3339Nano),
	)
	if err != nil {
		if isSQLiteConstraint(err) {
			return nil, ErrDuplicateFile
		}
		return nil, fmt.Errorf("metadata: create file: %w", err)
	}
	return f, nil
}

// GetFileByID returns the file with the given ID (including soft-deleted).
func (d *DB) GetFileByID(id string) (*File, error) {
	row := d.db.QueryRow(
		`SELECT id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type, created_at, updated_at, deleted_at
		 FROM files WHERE id = ?`, id,
	)
	return scanFile(row)
}

// ListChildren returns all non-deleted children of parentID, sorted dirs first, then by name.
// Pass empty string for parentID to list root items (NULL parent).
func (d *DB) ListChildren(parentID string) ([]File, error) {
	var rows *sql.Rows
	var err error
	if parentID == "" {
		rows, err = d.db.Query(
			`SELECT id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type, created_at, updated_at, deleted_at
			 FROM files WHERE parent_id IS NULL AND deleted_at IS NULL
			 ORDER BY is_dir DESC, name`,
		)
	} else {
		rows, err = d.db.Query(
			`SELECT id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type, created_at, updated_at, deleted_at
			 FROM files WHERE parent_id = ? AND deleted_at IS NULL
			 ORDER BY is_dir DESC, name`,
			parentID,
		)
	}
	if err != nil {
		return nil, fmt.Errorf("metadata: list children: %w", err)
	}
	defer rows.Close()

	var files []File
	for rows.Next() {
		f, err := scanFileRow(rows)
		if err != nil {
			return nil, err
		}
		files = append(files, *f)
	}
	return files, rows.Err()
}

// MoveFile moves a file to a new parent and/or renames it.
func (d *DB) MoveFile(id, newParentID, newName string) error {
	now := time.Now().UTC()
	var newParent interface{}
	if newParentID != "" {
		newParent = newParentID
	}
	res, err := d.db.Exec(
		`UPDATE files SET parent_id=?, name=?, updated_at=? WHERE id=? AND deleted_at IS NULL`,
		newParent, newName, now.Format(time.RFC3339Nano), id,
	)
	if err != nil {
		if isSQLiteConstraint(err) {
			return ErrDuplicateFile
		}
		return fmt.Errorf("metadata: move file: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrFileNotFound
	}
	return nil
}

// SoftDeleteFile marks the file as deleted by setting deleted_at to now.
func (d *DB) SoftDeleteFile(id string) error {
	now := time.Now().UTC()
	res, err := d.db.Exec(
		`UPDATE files SET deleted_at=?, updated_at=? WHERE id=? AND deleted_at IS NULL`,
		now.Format(time.RFC3339Nano), now.Format(time.RFC3339Nano), id,
	)
	if err != nil {
		return fmt.Errorf("metadata: soft delete file: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrFileNotFound
	}
	return nil
}

// UpdateFileContent updates the content hash and size of a file after a new version is stored.
func (d *DB) UpdateFileContent(id, contentHash string, size int64) error {
	now := time.Now().UTC()
	res, err := d.db.Exec(
		`UPDATE files SET content_hash=?, size=?, updated_at=? WHERE id=? AND deleted_at IS NULL`,
		contentHash, size, now.Format(time.RFC3339Nano), id,
	)
	if err != nil {
		return fmt.Errorf("metadata: update file content: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrFileNotFound
	}
	return nil
}

// StorageUsedByUser returns the sum of sizes of all non-deleted, non-directory files owned by userID.
func (d *DB) StorageUsedByUser(userID string) (int64, error) {
	var total sql.NullInt64
	err := d.db.QueryRow(
		`SELECT SUM(size) FROM files WHERE owner_id=? AND is_dir=0 AND deleted_at IS NULL`,
		userID,
	).Scan(&total)
	if err != nil {
		return 0, fmt.Errorf("metadata: storage used by user: %w", err)
	}
	if !total.Valid {
		return 0, nil
	}
	return total.Int64, nil
}

// scanFile scans a single File from a *sql.Row.
func scanFile(row *sql.Row) (*File, error) {
	var f File
	var isDirInt int
	var createdAt, updatedAt string
	err := row.Scan(
		&f.ID, &f.ParentID, &f.OwnerID, &f.Name, &isDirInt,
		&f.Size, &f.ContentHash, &f.MimeType,
		&createdAt, &updatedAt, &f.DeletedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrFileNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("metadata: scan file: %w", err)
	}
	f.IsDir = isDirInt != 0
	f.CreatedAt, _ = time.Parse(time.RFC3339Nano, createdAt)
	f.UpdatedAt, _ = time.Parse(time.RFC3339Nano, updatedAt)
	return &f, nil
}

// scanFileRow scans a single File from *sql.Rows.
func scanFileRow(rows *sql.Rows) (*File, error) {
	var f File
	var isDirInt int
	var createdAt, updatedAt string
	err := rows.Scan(
		&f.ID, &f.ParentID, &f.OwnerID, &f.Name, &isDirInt,
		&f.Size, &f.ContentHash, &f.MimeType,
		&createdAt, &updatedAt, &f.DeletedAt,
	)
	if err != nil {
		return nil, fmt.Errorf("metadata: scan file row: %w", err)
	}
	f.IsDir = isDirInt != 0
	f.CreatedAt, _ = time.Parse(time.RFC3339Nano, createdAt)
	f.UpdatedAt, _ = time.Parse(time.RFC3339Nano, updatedAt)
	return &f, nil
}

// nullStringVal returns nil if ns is not valid, else the string value.
func nullStringVal(ns sql.NullString) interface{} {
	if ns.Valid {
		return ns.String
	}
	return nil
}
