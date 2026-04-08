package metadata

import (
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

// Version represents a stored version of a file.
type Version struct {
	ID          string
	FileID      string
	VersionNum  int
	ContentHash string
	PatchHash   sql.NullString
	Size        int64
	CreatedBy   string
	CreatedAt   time.Time
}

// ErrVersionNotFound is returned when a version cannot be found.
var ErrVersionNotFound = errors.New("metadata: version not found")

// CreateVersion inserts a new version record and returns the created Version.
func (d *DB) CreateVersion(fileID string, versionNum int, contentHash, patchHash string, size int64, createdBy string) (*Version, error) {
	now := time.Now().UTC()
	v := &Version{
		ID:          uuid.New().String(),
		FileID:      fileID,
		VersionNum:  versionNum,
		ContentHash: contentHash,
		Size:        size,
		CreatedBy:   createdBy,
		CreatedAt:   now,
	}
	if patchHash != "" {
		v.PatchHash = sql.NullString{String: patchHash, Valid: true}
	}

	_, err := d.db.Exec(
		`INSERT INTO versions (id, file_id, version_num, content_hash, patch_hash, size, created_by, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		v.ID, v.FileID, v.VersionNum, v.ContentHash,
		nullStringVal(v.PatchHash),
		v.Size, v.CreatedBy,
		v.CreatedAt.Format(time.RFC3339Nano),
	)
	if err != nil {
		return nil, fmt.Errorf("metadata: create version: %w", err)
	}

	// Keep files.size and files.content_hash in sync with latest version
	d.db.Exec(
		`UPDATE files SET size = ?, content_hash = ?, updated_at = ? WHERE id = ?`,
		v.Size, v.ContentHash, now.Format(time.RFC3339Nano), v.FileID,
	)

	// Update ancestor folder sizes after file size change.
	d.updateAncestorSizes(v.FileID)

	return v, nil
}

// ListVersions returns all versions for fileID, newest first.
func (d *DB) ListVersions(fileID string) ([]Version, error) {
	rows, err := d.db.Query(
		`SELECT id, file_id, version_num, content_hash, patch_hash, size, created_by, created_at
		 FROM versions WHERE file_id = ? ORDER BY version_num DESC`,
		fileID,
	)
	if err != nil {
		return nil, fmt.Errorf("metadata: list versions: %w", err)
	}
	defer rows.Close()

	var versions []Version
	for rows.Next() {
		v, err := scanVersionRow(rows)
		if err != nil {
			return nil, err
		}
		versions = append(versions, *v)
	}
	return versions, rows.Err()
}

// GetLatestVersion returns the version with the highest version_num for fileID.
func (d *DB) GetLatestVersion(fileID string) (*Version, error) {
	row := d.db.QueryRow(
		`SELECT id, file_id, version_num, content_hash, patch_hash, size, created_by, created_at
		 FROM versions WHERE file_id = ? ORDER BY version_num DESC LIMIT 1`,
		fileID,
	)
	v, err := scanVersion(row)
	if errors.Is(err, ErrVersionNotFound) {
		return nil, ErrVersionNotFound
	}
	return v, err
}

// GetVersionByNum returns the version with the given version_num for fileID.
func (d *DB) GetVersionByNum(fileID string, num int) (*Version, error) {
	row := d.db.QueryRow(
		`SELECT id, file_id, version_num, content_hash, patch_hash, size, created_by, created_at
		 FROM versions WHERE file_id = ? AND version_num = ?`,
		fileID, num,
	)
	return scanVersion(row)
}

// CountVersions returns the number of versions for fileID.
func (d *DB) CountVersions(fileID string) (int, error) {
	var count int
	err := d.db.QueryRow(
		`SELECT COUNT(*) FROM versions WHERE file_id = ?`, fileID,
	).Scan(&count)
	if err != nil {
		return 0, fmt.Errorf("metadata: count versions: %w", err)
	}
	return count, nil
}

// DeleteOldestVersion removes the version with the lowest version_num for fileID.
func (d *DB) DeleteOldestVersion(fileID string) error {
	res, err := d.db.Exec(
		`DELETE FROM versions WHERE id = (
			SELECT id FROM versions WHERE file_id = ? ORDER BY version_num ASC LIMIT 1
		)`,
		fileID,
	)
	if err != nil {
		return fmt.Errorf("metadata: delete oldest version: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrVersionNotFound
	}
	return nil
}

// DeleteVersion removes the version with the given id.
func (d *DB) DeleteVersion(id string) error {
	res, err := d.db.Exec(`DELETE FROM versions WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("metadata: delete version: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrVersionNotFound
	}
	return nil
}

// DeleteVersionsOlderThan removes all versions for fileID created before the
// given time and returns the number of rows deleted.
func (d *DB) DeleteVersionsOlderThan(fileID string, before time.Time) (int64, error) {
	res, err := d.db.Exec(
		`DELETE FROM versions WHERE file_id = ? AND created_at < ?`,
		fileID, before.UTC().Format(time.RFC3339Nano),
	)
	if err != nil {
		return 0, fmt.Errorf("metadata: delete versions older than: %w", err)
	}
	n, _ := res.RowsAffected()
	return n, nil
}

// scanVersion scans a single Version from a *sql.Row.
func scanVersion(row *sql.Row) (*Version, error) {
	var v Version
	var createdAt string
	err := row.Scan(
		&v.ID, &v.FileID, &v.VersionNum, &v.ContentHash,
		&v.PatchHash, &v.Size, &v.CreatedBy, &createdAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrVersionNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("metadata: scan version: %w", err)
	}
	v.CreatedAt, _ = time.Parse(time.RFC3339Nano, createdAt)
	return &v, nil
}

// scanVersionRow scans a single Version from *sql.Rows.
func scanVersionRow(rows *sql.Rows) (*Version, error) {
	var v Version
	var createdAt string
	err := rows.Scan(
		&v.ID, &v.FileID, &v.VersionNum, &v.ContentHash,
		&v.PatchHash, &v.Size, &v.CreatedBy, &createdAt,
	)
	if err != nil {
		return nil, fmt.Errorf("metadata: scan version row: %w", err)
	}
	v.CreatedAt, _ = time.Parse(time.RFC3339Nano, createdAt)
	return &v, nil
}
