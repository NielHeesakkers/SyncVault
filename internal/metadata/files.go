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
	ID             string
	ParentID       sql.NullString
	OwnerID        string
	Name           string
	IsDir          bool
	Size           int64
	ContentHash    sql.NullString
	MimeType       sql.NullString
	CreatedAt      time.Time
	UpdatedAt      time.Time
	DeletedAt      sql.NullString
	RemovedLocally bool
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

	// If a file/folder with the same name exists (including soft-deleted), rename the old one to trash
	trashSuffix := "_DELETED_" + f.CreatedAt.Format("2006-01-02_150405")
	if parentID != "" {
		d.db.Exec(`UPDATE files SET name = name || ?, deleted_at = COALESCE(deleted_at, ?) WHERE parent_id = ? AND owner_id = ? AND name = ?`,
			trashSuffix, f.CreatedAt.Format(time.RFC3339Nano), parentID, ownerID, name)
	} else {
		d.db.Exec(`UPDATE files SET name = name || ?, deleted_at = COALESCE(deleted_at, ?) WHERE parent_id IS NULL AND owner_id = ? AND name = ?`,
			trashSuffix, f.CreatedAt.Format(time.RFC3339Nano), ownerID, name)
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
		`SELECT id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type, created_at, updated_at, deleted_at, removed_locally
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
			`SELECT id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type, created_at, updated_at, deleted_at, removed_locally
			 FROM files WHERE parent_id IS NULL AND deleted_at IS NULL
			 ORDER BY is_dir DESC, name`,
		)
	} else {
		rows, err = d.db.Query(
			`SELECT id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type, created_at, updated_at, deleted_at, removed_locally
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

// GetFolderSize returns the total size of all non-deleted files recursively under a folder.
func (d *DB) GetFolderSize(folderID string) (int64, error) {
	var size int64
	err := d.db.QueryRow(
		`WITH RECURSIVE descendants(id) AS (
		   SELECT id FROM files WHERE parent_id = ? AND deleted_at IS NULL
		   UNION ALL
		   SELECT f.id FROM files f JOIN descendants d ON f.parent_id = d.id WHERE f.deleted_at IS NULL
		 )
		 SELECT COALESCE(SUM(f.size), 0)
		 FROM files f
		 WHERE f.id IN (SELECT id FROM descendants) AND f.is_dir = 0`,
		folderID,
	).Scan(&size)
	return size, err
}

// TransferAllFiles changes the owner of ALL files from one user to another.
func (d *DB) TransferAllFiles(fromUserID, toUserID string) error {
	_, err := d.db.Exec(`UPDATE files SET owner_id = ? WHERE owner_id = ?`, toUserID, fromUserID)
	return err
}

// UpdateFileOwner changes the owner of a file.
func (d *DB) UpdateFileOwner(id, newOwnerID string) error {
	_, err := d.db.Exec(`UPDATE files SET owner_id=? WHERE id=?`, newOwnerID, id)
	return err
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

// RestoreFile clears the deleted_at field for the given file, restoring it from trash.
func (d *DB) RestoreFile(id string) error {
	now := time.Now().UTC()
	res, err := d.db.Exec(
		`UPDATE files SET deleted_at=NULL, updated_at=? WHERE id=? AND deleted_at IS NOT NULL`,
		now.Format(time.RFC3339Nano), id,
	)
	if err != nil {
		return fmt.Errorf("metadata: restore file: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrFileNotFound
	}
	return nil
}

// ListTrashedFiles returns all soft-deleted files owned by ownerID.
func (d *DB) ListTrashedFiles(ownerID string) ([]File, error) {
	rows, err := d.db.Query(
		`SELECT id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type, created_at, updated_at, deleted_at, removed_locally
		 FROM files WHERE owner_id=? AND deleted_at IS NOT NULL
		 ORDER BY deleted_at DESC`,
		ownerID,
	)
	if err != nil {
		return nil, fmt.Errorf("metadata: list trashed files: %w", err)
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

// ListAllTrashedFiles returns all soft-deleted files across all users (admin view).
func (d *DB) ListAllTrashedFiles() ([]File, error) {
	rows, err := d.db.Query(
		`SELECT id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type, created_at, updated_at, deleted_at, removed_locally
		 FROM files WHERE deleted_at IS NOT NULL
		 ORDER BY deleted_at DESC`,
	)
	if err != nil {
		return nil, fmt.Errorf("metadata: list all trashed files: %w", err)
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

// ListChangedFiles returns all files (including soft-deleted) owned by ownerID where updated_at or deleted_at
// is strictly after the given since timestamp. This is used by sync clients to poll for remote changes.
func (d *DB) ListChangedFiles(since time.Time, ownerID string) ([]File, error) {
	sinceStr := since.UTC().Format(time.RFC3339Nano)
	rows, err := d.db.Query(
		`SELECT id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type, created_at, updated_at, deleted_at, removed_locally
		 FROM files
		 WHERE owner_id = ?
		   AND (updated_at > ? OR deleted_at > ?)
		 ORDER BY updated_at ASC`,
		ownerID, sinceStr, sinceStr,
	)
	if err != nil {
		return nil, fmt.Errorf("metadata: list changed files: %w", err)
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

// FolderSizeEntry holds a folder's ID, name, and total size of its contents.
type FolderSizeEntry struct {
	ID   string
	Name string
	Size int64
}

// ListTopFoldersBySize returns top-level folders ordered by total file size descending.
func (d *DB) ListTopFoldersBySize() ([]FolderSizeEntry, error) {
	rows, err := d.db.Query(
		`SELECT f.id, f.name, COALESCE(SUM(c.size), 0) as total_size
		 FROM files f
		 LEFT JOIN files c ON c.parent_id = f.id AND c.is_dir = 0 AND c.deleted_at IS NULL
		 WHERE f.is_dir = 1 AND f.parent_id IS NULL AND f.deleted_at IS NULL
		 GROUP BY f.id, f.name
		 ORDER BY total_size DESC
		 LIMIT 50`,
	)
	if err != nil {
		return nil, fmt.Errorf("metadata: list top folders by size: %w", err)
	}
	defer rows.Close()

	var entries []FolderSizeEntry
	for rows.Next() {
		var e FolderSizeEntry
		if err := rows.Scan(&e.ID, &e.Name, &e.Size); err != nil {
			return nil, fmt.Errorf("metadata: scan folder size entry: %w", err)
		}
		entries = append(entries, e)
	}
	return entries, rows.Err()
}

// scanFile scans a single File from a *sql.Row.
func scanFile(row *sql.Row) (*File, error) {
	var f File
	var isDirInt, removedLocallyInt int
	var createdAt, updatedAt string
	err := row.Scan(
		&f.ID, &f.ParentID, &f.OwnerID, &f.Name, &isDirInt,
		&f.Size, &f.ContentHash, &f.MimeType,
		&createdAt, &updatedAt, &f.DeletedAt, &removedLocallyInt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrFileNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("metadata: scan file: %w", err)
	}
	f.IsDir = isDirInt != 0
	f.RemovedLocally = removedLocallyInt != 0
	f.CreatedAt, _ = time.Parse(time.RFC3339Nano, createdAt)
	f.UpdatedAt, _ = time.Parse(time.RFC3339Nano, updatedAt)
	return &f, nil
}

// scanFileRow scans a single File from *sql.Rows.
func scanFileRow(rows *sql.Rows) (*File, error) {
	var f File
	var isDirInt, removedLocallyInt int
	var createdAt, updatedAt string
	err := rows.Scan(
		&f.ID, &f.ParentID, &f.OwnerID, &f.Name, &isDirInt,
		&f.Size, &f.ContentHash, &f.MimeType,
		&createdAt, &updatedAt, &f.DeletedAt, &removedLocallyInt,
	)
	if err != nil {
		return nil, fmt.Errorf("metadata: scan file row: %w", err)
	}
	f.IsDir = isDirInt != 0
	f.RemovedLocally = removedLocallyInt != 0
	f.CreatedAt, _ = time.Parse(time.RFC3339Nano, createdAt)
	f.UpdatedAt, _ = time.Parse(time.RFC3339Nano, updatedAt)
	return &f, nil
}

// FileAtTime represents a file as it existed at a particular point in time,
// joined with the version that was current at that moment.
type FileAtTime struct {
	ID          string
	Name        string
	IsDir       bool
	ParentID    sql.NullString
	OwnerID     string
	VersionNum  int
	VersionID   string
	ContentHash string
	Size        int64
	CreatedAt   time.Time
	UpdatedAt   time.Time
}

// ListFilesAtTime returns the files that existed under parentID (owned by ownerID)
// at the given point in time, together with the version that was current at that moment.
func (d *DB) ListFilesAtTime(parentID string, ownerID string, at time.Time) ([]FileAtTime, error) {
	atStr := at.UTC().Format(time.RFC3339Nano)

	var rows *sql.Rows
	var err error
	if parentID == "" && ownerID == "" {
		// Admin: all root files
		rows, err = d.db.Query(
			`SELECT f.id, f.name, f.is_dir, f.parent_id, f.owner_id,
			        COALESCE(v.version_num, 0) as version_num,
			        COALESCE(v.id, '') as version_id,
			        COALESCE(v.content_hash, f.content_hash, '') as content_hash,
			        COALESCE(v.size, f.size) as size,
			        f.created_at, f.updated_at
			 FROM files f
			 LEFT JOIN versions v ON v.file_id = f.id AND v.created_at <= ?
			   AND v.version_num = (
			     SELECT MAX(v2.version_num) FROM versions v2
			     WHERE v2.file_id = f.id AND v2.created_at <= ?
			   )
			 WHERE f.parent_id IS NULL
			   AND f.created_at <= ?
			   AND (f.deleted_at IS NULL OR f.deleted_at > ?)
			 ORDER BY f.is_dir DESC, f.name`,
			atStr, atStr, atStr, atStr,
		)
	} else if parentID == "" {
		rows, err = d.db.Query(
			`SELECT f.id, f.name, f.is_dir, f.parent_id, f.owner_id,
			        COALESCE(v.version_num, 0) as version_num,
			        COALESCE(v.id, '') as version_id,
			        COALESCE(v.content_hash, f.content_hash, '') as content_hash,
			        COALESCE(v.size, f.size) as size,
			        f.created_at, f.updated_at
			 FROM files f
			 LEFT JOIN versions v ON v.file_id = f.id AND v.created_at <= ?
			   AND v.version_num = (
			     SELECT MAX(v2.version_num) FROM versions v2
			     WHERE v2.file_id = f.id AND v2.created_at <= ?
			   )
			 WHERE f.owner_id = ?
			   AND f.parent_id IS NULL
			   AND f.created_at <= ?
			   AND (f.deleted_at IS NULL OR f.deleted_at > ?)
			 ORDER BY f.is_dir DESC, f.name`,
			atStr, atStr, ownerID, atStr, atStr,
		)
	} else if ownerID == "" {
		// Admin: all files in folder regardless of owner
		rows, err = d.db.Query(
			`SELECT f.id, f.name, f.is_dir, f.parent_id, f.owner_id,
			        COALESCE(v.version_num, 0) as version_num,
			        COALESCE(v.id, '') as version_id,
			        COALESCE(v.content_hash, f.content_hash, '') as content_hash,
			        COALESCE(v.size, f.size) as size,
			        f.created_at, f.updated_at
			 FROM files f
			 LEFT JOIN versions v ON v.file_id = f.id AND v.created_at <= ?
			   AND v.version_num = (
			     SELECT MAX(v2.version_num) FROM versions v2
			     WHERE v2.file_id = f.id AND v2.created_at <= ?
			   )
			 WHERE f.parent_id = ?
			   AND f.created_at <= ?
			   AND (f.deleted_at IS NULL OR f.deleted_at > ?)
			 ORDER BY f.is_dir DESC, f.name`,
			atStr, atStr, parentID, atStr, atStr,
		)
	} else {
		rows, err = d.db.Query(
			`SELECT f.id, f.name, f.is_dir, f.parent_id, f.owner_id,
			        COALESCE(v.version_num, 0) as version_num,
			        COALESCE(v.id, '') as version_id,
			        COALESCE(v.content_hash, f.content_hash, '') as content_hash,
			        COALESCE(v.size, f.size) as size,
			        f.created_at, f.updated_at
			 FROM files f
			 LEFT JOIN versions v ON v.file_id = f.id AND v.created_at <= ?
			   AND v.version_num = (
			     SELECT MAX(v2.version_num) FROM versions v2
			     WHERE v2.file_id = f.id AND v2.created_at <= ?
			   )
			 WHERE f.owner_id = ?
			   AND f.parent_id = ?
			   AND f.created_at <= ?
			   AND (f.deleted_at IS NULL OR f.deleted_at > ?)
			 ORDER BY f.is_dir DESC, f.name`,
			atStr, atStr, ownerID, parentID, atStr, atStr,
		)
	}
	if err != nil {
		return nil, fmt.Errorf("metadata: list files at time: %w", err)
	}
	defer rows.Close()

	var files []FileAtTime
	for rows.Next() {
		var f FileAtTime
		var isDirInt int
		var createdAt, updatedAt string
		if err := rows.Scan(
			&f.ID, &f.Name, &isDirInt, &f.ParentID, &f.OwnerID,
			&f.VersionNum, &f.VersionID, &f.ContentHash, &f.Size,
			&createdAt, &updatedAt,
		); err != nil {
			return nil, fmt.Errorf("metadata: scan file at time: %w", err)
		}
		f.IsDir = isDirInt != 0
		f.CreatedAt, _ = time.Parse(time.RFC3339Nano, createdAt)
		f.UpdatedAt, _ = time.Parse(time.RFC3339Nano, updatedAt)
		files = append(files, f)
	}
	return files, rows.Err()
}

// ListChangeDates returns the distinct dates (YYYY-MM-DD) on which versions were created
// for files under parentID owned by ownerID, most recent first (up to 100).
func (d *DB) ListChangeDates(parentID, ownerID string) ([]time.Time, error) {
	var rows *sql.Rows
	var err error
	if parentID == "" && ownerID == "" {
		// Admin: all change dates
		rows, err = d.db.Query(
			`SELECT DISTINCT date(v.created_at) as change_date
			 FROM versions v
			 ORDER BY change_date DESC
			 LIMIT 100`,
		)
	} else if parentID == "" {
		rows, err = d.db.Query(
			`SELECT DISTINCT date(v.created_at) as change_date
			 FROM versions v
			 JOIN files f ON f.id = v.file_id
			 WHERE f.owner_id = ?
			 ORDER BY change_date DESC
			 LIMIT 100`,
			ownerID,
		)
	} else if ownerID == "" {
		// Admin: all change dates in folder
		rows, err = d.db.Query(
			`WITH RECURSIVE descendants(id) AS (
			   SELECT id FROM files WHERE parent_id = ?
			   UNION ALL
			   SELECT f.id FROM files f JOIN descendants d ON f.parent_id = d.id
			 )
			 SELECT DISTINCT date(v.created_at) as change_date
			 FROM versions v
			 JOIN files f ON f.id = v.file_id
			 WHERE f.id IN (SELECT id FROM descendants)
			 ORDER BY change_date DESC
			 LIMIT 100`,
			parentID,
		)
	} else {
		rows, err = d.db.Query(
			`WITH RECURSIVE descendants(id) AS (
			   SELECT id FROM files WHERE parent_id = ? AND owner_id = ?
			   UNION ALL
			   SELECT f.id FROM files f JOIN descendants d ON f.parent_id = d.id
			 )
			 SELECT DISTINCT date(v.created_at) as change_date
			 FROM versions v
			 JOIN files f ON f.id = v.file_id
			 WHERE f.id IN (SELECT id FROM descendants)
			 ORDER BY change_date DESC
			 LIMIT 100`,
			parentID, ownerID,
		)
	}
	if err != nil {
		return nil, fmt.Errorf("metadata: list change dates: %w", err)
	}
	defer rows.Close()

	var dates []time.Time
	for rows.Next() {
		var dateStr string
		if err := rows.Scan(&dateStr); err != nil {
			return nil, fmt.Errorf("metadata: scan change date: %w", err)
		}
		t, err := time.Parse("2006-01-02", dateStr)
		if err != nil {
			continue
		}
		dates = append(dates, t)
	}
	return dates, rows.Err()
}

// MarkRemovedLocally sets removed_locally=1 for the given file.
func (d *DB) MarkRemovedLocally(fileID string) error {
	res, err := d.db.Exec(`UPDATE files SET removed_locally=1 WHERE id=?`, fileID)
	if err != nil {
		return fmt.Errorf("metadata: mark removed locally: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrFileNotFound
	}
	return nil
}

// UnmarkRemovedLocally sets removed_locally=0 for the given file.
func (d *DB) UnmarkRemovedLocally(fileID string) error {
	res, err := d.db.Exec(`UPDATE files SET removed_locally=0 WHERE id=?`, fileID)
	if err != nil {
		return fmt.Errorf("metadata: unmark removed locally: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrFileNotFound
	}
	return nil
}

// PreviewCleanup returns the count of files, versions, and total bytes that would
// be deleted by ExecuteCleanup with the same parameters, without making any changes.
func (d *DB) PreviewCleanup(beforeDate time.Time, includeVersions, onlyDeleted bool) (fileCount, versionCount int, totalBytes int64, err error) {
	beforeStr := beforeDate.UTC().Format(time.RFC3339Nano)

	// Count matching files.
	fileQuery := `SELECT COUNT(*), COALESCE(SUM(size), 0) FROM files WHERE created_at < ? AND is_dir = 0`
	if onlyDeleted {
		fileQuery += ` AND deleted_at IS NOT NULL`
	}
	if err = d.db.QueryRow(fileQuery, beforeStr).Scan(&fileCount, &totalBytes); err != nil {
		return 0, 0, 0, fmt.Errorf("metadata: preview cleanup files: %w", err)
	}

	// Count matching versions.
	if includeVersions {
		versionQuery := `SELECT COUNT(*), COALESCE(SUM(v.size), 0)
			FROM versions v
			JOIN files f ON f.id = v.file_id
			WHERE v.created_at < ?`
		if onlyDeleted {
			versionQuery += ` AND f.deleted_at IS NOT NULL`
		}
		var versionBytes int64
		if err = d.db.QueryRow(versionQuery, beforeStr).Scan(&versionCount, &versionBytes); err != nil {
			return 0, 0, 0, fmt.Errorf("metadata: preview cleanup versions: %w", err)
		}
		totalBytes += versionBytes
	}

	return fileCount, versionCount, totalBytes, nil
}

// ExecuteCleanup permanently deletes files (and optionally versions) created before
// beforeDate. If onlyDeleted is true, only soft-deleted files are targeted.
// Returns the counts of deleted files and versions and the total bytes freed.
// Callers must also delete the corresponding storage chunks using the returned hashes.
func (d *DB) ExecuteCleanup(beforeDate time.Time, includeVersions, onlyDeleted bool) (fileCount, versionCount int, totalBytes int64, err error) {
	beforeStr := beforeDate.UTC().Format(time.RFC3339Nano)

	// Collect content hashes of files to delete so the caller can remove chunks.
	fileQuery := `SELECT id, content_hash, size FROM files WHERE created_at < ? AND is_dir = 0`
	if onlyDeleted {
		fileQuery += ` AND deleted_at IS NOT NULL`
	}
	rows, err := d.db.Query(fileQuery, beforeStr)
	if err != nil {
		return 0, 0, 0, fmt.Errorf("metadata: execute cleanup list files: %w", err)
	}

	type fileRow struct {
		id          string
		contentHash sql.NullString
		size        int64
	}
	var filesToDelete []fileRow
	for rows.Next() {
		var fr fileRow
		if err = rows.Scan(&fr.id, &fr.contentHash, &fr.size); err != nil {
			rows.Close()
			return 0, 0, 0, fmt.Errorf("metadata: execute cleanup scan file: %w", err)
		}
		filesToDelete = append(filesToDelete, fr)
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return 0, 0, 0, fmt.Errorf("metadata: execute cleanup rows: %w", err)
	}

	for _, fr := range filesToDelete {
		totalBytes += fr.size

		// Delete versions for this file first.
		if includeVersions {
			var vRows *sql.Rows
			vRows, err = d.db.Query(`SELECT id, size FROM versions WHERE file_id = ?`, fr.id)
			if err != nil {
				return fileCount, versionCount, totalBytes, fmt.Errorf("metadata: execute cleanup list versions: %w", err)
			}
			for vRows.Next() {
				var vid string
				var vsz int64
				if err = vRows.Scan(&vid, &vsz); err != nil {
					vRows.Close()
					return fileCount, versionCount, totalBytes, fmt.Errorf("metadata: execute cleanup scan version: %w", err)
				}
				if _, err = d.db.Exec(`DELETE FROM versions WHERE id = ?`, vid); err != nil {
					vRows.Close()
					return fileCount, versionCount, totalBytes, fmt.Errorf("metadata: execute cleanup delete version: %w", err)
				}
				versionCount++
			}
			vRows.Close()
		}

		if _, err = d.db.Exec(`DELETE FROM files WHERE id = ?`, fr.id); err != nil {
			return fileCount, versionCount, totalBytes, fmt.Errorf("metadata: execute cleanup delete file: %w", err)
		}
		fileCount++
	}

	return fileCount, versionCount, totalBytes, nil
}

// GetDataCalendar returns a map of "YYYY-MM" -> sorted list of day numbers (1-31)
// on which file or version activity occurred.
func (d *DB) GetDataCalendar() (map[string][]int, error) {
	rows, err := d.db.Query(`
		SELECT DISTINCT strftime('%Y-%m', created_at) as month,
		       CAST(strftime('%d', created_at) AS INTEGER) as day
		FROM files
		WHERE owner_id IN (SELECT id FROM users)
		UNION
		SELECT DISTINCT strftime('%Y-%m', created_at) as month,
		       CAST(strftime('%d', created_at) AS INTEGER) as day
		FROM versions
		ORDER BY month, day
	`)
	if err != nil {
		return nil, fmt.Errorf("metadata: get data calendar: %w", err)
	}
	defer rows.Close()

	result := make(map[string][]int)
	for rows.Next() {
		var month string
		var day int
		if err = rows.Scan(&month, &day); err != nil {
			return nil, fmt.Errorf("metadata: get data calendar scan: %w", err)
		}
		result[month] = append(result[month], day)
	}
	return result, rows.Err()
}

// nullStringVal returns nil if ns is not valid, else the string value.
func nullStringVal(ns sql.NullString) interface{} {
	if ns.Valid {
		return ns.String
	}
	return nil
}
