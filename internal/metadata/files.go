package metadata

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
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
	FolderSize     int64
}

// ErrFileNotFound is returned when a file cannot be found.
var ErrFileNotFound = errors.New("metadata: file not found")

// ErrDuplicateFile is returned when creating a file with a conflicting name in the same parent.
var ErrDuplicateFile = errors.New("metadata: duplicate file name in parent")

// nextChangeRank returns the next change_rank value atomically.
// Uses UPDATE...RETURNING to prevent duplicate ranks under concurrent access.
func (d *DB) nextChangeRank() int64 {
	// Ensure counter row exists
	d.db.Exec(`INSERT OR IGNORE INTO settings (key, value) VALUES ('_change_rank', '0')`)
	var rank int64
	err := d.db.QueryRow(`UPDATE settings SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT) WHERE key = '_change_rank' RETURNING CAST(value AS INTEGER)`).Scan(&rank)
	if err != nil {
		// Fallback to old method if settings table doesn't support RETURNING
		d.db.QueryRow(`SELECT COALESCE(MAX(change_rank), 0) + 1 FROM files`).Scan(&rank)
	}
	return rank
}

// updateAncestorSizes recalculates folder_size for the given file's parent and all ancestors.
// Each folder's size is the sum of its direct children's sizes (files use size, dirs use folder_size).
// Called after any file mutation (create, update size, delete, restore).
// Uses a transaction to prevent inconsistent sizes under concurrent access.
func (d *DB) updateAncestorSizes(fileID string) {
	tx, err := d.db.Begin()
	if err != nil {
		return
	}
	defer tx.Rollback()

	var parentID sql.NullString
	tx.QueryRow(`SELECT parent_id FROM files WHERE id = ?`, fileID).Scan(&parentID)

	for parentID.Valid {
		tx.Exec(`UPDATE files SET folder_size = (
			SELECT COALESCE(SUM(CASE WHEN is_dir = 1 THEN folder_size ELSE size END), 0)
			FROM files WHERE parent_id = ? AND deleted_at IS NULL
		) WHERE id = ?`, parentID.String, parentID.String)

		var nextParent sql.NullString
		tx.QueryRow(`SELECT parent_id FROM files WHERE id = ?`, parentID.String).Scan(&nextParent)
		parentID = nextParent
	}

	tx.Commit()
}

// updateFolderSizeChain recalculates folder_size for the given folder and all its ancestors.
func (d *DB) updateFolderSizeChain(folderID sql.NullString) {
	if !folderID.Valid {
		return
	}
	// Delegate to transaction-based implementation
	d.updateAncestorSizes(folderID.String)
}

// CreateFile inserts a new file or directory record.
// For directories: idempotent find-or-create — if a non-deleted directory with the same
// name already exists, it is returned directly (no rename, no conflict).
// For files: any existing record with the same name is renamed with a _DELETED_ suffix.
func (d *DB) CreateFile(parentID, ownerID, name string, isDir bool, size int64, contentHash, mimeType string) (*File, error) {
	now := time.Now().UTC()

	// For directories: check if an active one already exists and return it (idempotent).
	if isDir {
		existing, err := d.findActiveDir(parentID, ownerID, name)
		if err == nil && existing != nil {
			return existing, nil
		}
	}

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

	// Rename any existing file/folder with the same name (including soft-deleted) so the
	// UNIQUE(parent_id, name, owner_id) constraint won't block the insert.
	trashSuffix := "_DELETED_" + f.CreatedAt.Format("20060102_150405") + "_" + f.ID[:8]
	if parentID != "" {
		d.db.Exec(`UPDATE files SET name = name || ?, deleted_at = COALESCE(deleted_at, ?), updated_at = ? WHERE parent_id = ? AND owner_id = ? AND name = ?`,
			trashSuffix, f.CreatedAt.Format(time.RFC3339Nano), f.CreatedAt.Format(time.RFC3339Nano), parentID, ownerID, name)
	} else {
		d.db.Exec(`UPDATE files SET name = name || ?, deleted_at = COALESCE(deleted_at, ?), updated_at = ? WHERE parent_id IS NULL AND owner_id = ? AND name = ?`,
			trashSuffix, f.CreatedAt.Format(time.RFC3339Nano), f.CreatedAt.Format(time.RFC3339Nano), ownerID, name)
	}

	_, err := d.db.Exec(
		`INSERT INTO files (id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type, created_at, updated_at, change_rank)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
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
		d.nextChangeRank(),
	)
	if err != nil {
		if isSQLiteConstraint(err) {
			// Race: another thread created it between our check and insert.
			// For directories, find and return it.
			if isDir {
				existing, findErr := d.findActiveDir(parentID, ownerID, name)
				if findErr == nil && existing != nil {
					return existing, nil
				}
			}
			return nil, ErrDuplicateFile
		}
		return nil, fmt.Errorf("metadata: create file: %w", err)
	}

	// Update ancestor folder sizes if this file has a parent.
	if parentID != "" {
		d.updateAncestorSizes(f.ID)
	}

	return f, nil
}

// findActiveDir finds a non-deleted directory by name and parent.
func (d *DB) findActiveDir(parentID, ownerID, name string) (*File, error) {
	var row *sql.Row
	if parentID == "" {
		row = d.db.QueryRow(
			`SELECT id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type, created_at, updated_at, deleted_at, removed_locally, folder_size
			 FROM files WHERE parent_id IS NULL AND owner_id = ? AND name = ? AND is_dir = 1 AND deleted_at IS NULL`, ownerID, name,
		)
	} else {
		row = d.db.QueryRow(
			`SELECT id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type, created_at, updated_at, deleted_at, removed_locally, folder_size
			 FROM files WHERE parent_id = ? AND owner_id = ? AND name = ? AND is_dir = 1 AND deleted_at IS NULL`, parentID, ownerID, name,
		)
	}
	return scanFile(row)
}

// GetFileByID returns the file with the given ID (including soft-deleted).
func (d *DB) GetFileByID(id string) (*File, error) {
	row := d.db.QueryRow(
		`SELECT id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type, created_at, updated_at, deleted_at, removed_locally, folder_size
		 FROM files WHERE id = ?`, id,
	)
	return scanFile(row)
}

// FindFileByName finds a file by name, parent, and owner — including soft-deleted files.
func (d *DB) FindFileByName(parentID, ownerID, name string) (*File, error) {
	var row *sql.Row
	if parentID == "" {
		row = d.db.QueryRow(
			`SELECT id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type, created_at, updated_at, deleted_at, removed_locally, folder_size
			 FROM files WHERE parent_id IS NULL AND owner_id = ? AND name = ?`, ownerID, name,
		)
	} else {
		row = d.db.QueryRow(
			`SELECT id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type, created_at, updated_at, deleted_at, removed_locally, folder_size
			 FROM files WHERE parent_id = ? AND owner_id = ? AND name = ?`, parentID, ownerID, name,
		)
	}
	return scanFile(row)
}

// OwnerStorageUsed returns total bytes used by all files owned by the given user.
func (d *DB) OwnerStorageUsed(ownerID string) int64 {
	var size int64
	d.db.QueryRow(
		`SELECT COALESCE(SUM(size), 0) FROM files WHERE owner_id = ? AND is_dir = 0 AND deleted_at IS NULL`,
		ownerID,
	).Scan(&size)
	return size
}

// ListChildren returns all non-deleted children of parentID, sorted dirs first, then by name.
// Pass empty string for parentID to list root items (NULL parent).
func (d *DB) ListChildren(parentID string) ([]File, error) {
	var rows *sql.Rows
	var err error
	// files.size and files.content_hash are kept in sync by CreateVersion — no need to join versions
	if parentID == "" {
		rows, err = d.db.Query(
			`SELECT id, parent_id, owner_id, name, is_dir,
			        CASE WHEN is_dir = 1 THEN folder_size ELSE size END as size,
			        content_hash, mime_type, created_at, updated_at, deleted_at, removed_locally, folder_size
			 FROM files
			 WHERE parent_id IS NULL AND deleted_at IS NULL
			 ORDER BY is_dir DESC, name`,
		)
	} else {
		rows, err = d.db.Query(
			`SELECT id, parent_id, owner_id, name, is_dir,
			        CASE WHEN is_dir = 1 THEN folder_size ELSE size END as size,
			        content_hash, mime_type, created_at, updated_at, deleted_at, removed_locally, folder_size
			 FROM files
			 WHERE parent_id = ? AND deleted_at IS NULL
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

	// Remember old parent so we can update its folder_size after the move.
	var oldParentID sql.NullString
	d.db.QueryRow(`SELECT parent_id FROM files WHERE id = ?`, id).Scan(&oldParentID)

	var newParent interface{}
	if newParentID != "" {
		newParent = newParentID
	}
	res, err := d.db.Exec(
		`UPDATE files SET parent_id=?, name=?, updated_at=?, change_rank=? WHERE id=? AND deleted_at IS NULL`,
		newParent, newName, now.Format(time.RFC3339Nano), d.nextChangeRank(), id,
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

	// Update folder sizes for both old and new parent trees.
	d.updateFolderSizeChain(oldParentID)
	d.updateAncestorSizes(id)

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
		`UPDATE files SET deleted_at=?, updated_at=?, change_rank=? WHERE id=? AND deleted_at IS NULL`,
		now.Format(time.RFC3339Nano), now.Format(time.RFC3339Nano), d.nextChangeRank(), id,
	)
	if err != nil {
		return fmt.Errorf("metadata: soft delete file: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrFileNotFound
	}

	// Update ancestor folder sizes after soft delete.
	d.updateAncestorSizes(id)

	return nil
}

// RestoreFile clears the deleted_at field for the given file, restoring it from trash.
func (d *DB) RestoreFile(id string) error {
	now := time.Now().UTC()
	res, err := d.db.Exec(
		`UPDATE files SET deleted_at=NULL, updated_at=?, change_rank=? WHERE id=? AND deleted_at IS NOT NULL`,
		now.Format(time.RFC3339Nano), d.nextChangeRank(), id,
	)
	if err != nil {
		return fmt.Errorf("metadata: restore file: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrFileNotFound
	}

	// Update ancestor folder sizes after restore.
	d.updateAncestorSizes(id)

	return nil
}

// PurgeUserTrash permanently deletes all soft-deleted files for the given user.
// Deletes files first (no children), then folders (leaf-first via repeated passes).
func (d *DB) PurgeUserTrash(ownerID string) (int64, error) {
	// Temporarily disable FK checks for clean cascade delete
	d.db.Exec(`PRAGMA foreign_keys=OFF`)
	defer d.db.Exec(`PRAGMA foreign_keys=ON`)

	// Delete all dependent rows for trashed files
	d.db.Exec(`DELETE FROM versions WHERE file_id IN (SELECT id FROM files WHERE owner_id=? AND deleted_at IS NOT NULL)`, ownerID)
	d.db.Exec(`DELETE FROM file_blocks WHERE file_id IN (SELECT id FROM files WHERE owner_id=? AND deleted_at IS NOT NULL)`, ownerID)
	d.db.Exec(`DELETE FROM share_links WHERE file_id IN (SELECT id FROM files WHERE owner_id=? AND deleted_at IS NOT NULL)`, ownerID)

	// Then delete non-directory files
	res, err := d.db.Exec(
		`DELETE FROM files WHERE owner_id=? AND deleted_at IS NOT NULL AND is_dir=0`,
		ownerID,
	)
	if err != nil {
		return 0, fmt.Errorf("metadata: purge user trash files: %w", err)
	}
	total, _ := res.RowsAffected()

	// Then repeatedly delete leaf directories until none remain
	for i := 0; i < 50; i++ {
		res, err = d.db.Exec(
			`DELETE FROM files WHERE owner_id=? AND deleted_at IS NOT NULL AND is_dir=1
			 AND id NOT IN (SELECT DISTINCT parent_id FROM files WHERE parent_id IS NOT NULL)`,
			ownerID,
		)
		if err != nil {
			return total, fmt.Errorf("metadata: purge user trash dirs: %w", err)
		}
		n, _ := res.RowsAffected()
		total += n
		if n == 0 {
			break
		}
	}
	return total, nil
}

// PurgeAllTrash permanently deletes ALL soft-deleted files in a single transaction.
func (d *DB) PurgeAllTrash() (int64, error) {
	tx, err := d.db.Begin()
	if err != nil {
		return 0, fmt.Errorf("metadata: purge all trash begin tx: %w", err)
	}
	defer tx.Rollback()

	// Delete dependent rows for trashed files
	tx.Exec(`DELETE FROM versions WHERE file_id IN (SELECT id FROM files WHERE deleted_at IS NOT NULL)`)
	tx.Exec(`DELETE FROM file_blocks WHERE file_id IN (SELECT id FROM files WHERE deleted_at IS NOT NULL)`)
	tx.Exec(`DELETE FROM share_links WHERE file_id IN (SELECT id FROM files WHERE deleted_at IS NOT NULL)`)

	// Delete non-dir trashed files
	res, _ := tx.Exec(`DELETE FROM files WHERE deleted_at IS NOT NULL AND is_dir = 0`)
	total, _ := res.RowsAffected()

	// Delete trashed dirs leaf-first
	for i := 0; i < 50; i++ {
		res, _ = tx.Exec(`DELETE FROM files WHERE deleted_at IS NOT NULL AND is_dir = 1 AND id NOT IN (SELECT DISTINCT parent_id FROM files WHERE parent_id IS NOT NULL)`)
		n, _ := res.RowsAffected()
		total += n
		if n == 0 {
			break
		}
	}

	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("metadata: purge all trash commit: %w", err)
	}
	return total, nil
}

// PermanentlyDeleteFile removes a single file from the database entirely.
func (d *DB) PermanentlyDeleteFile(id string) error {
	res, err := d.db.Exec(`DELETE FROM files WHERE id=? AND deleted_at IS NOT NULL`, id)
	if err != nil {
		return fmt.Errorf("metadata: permanently delete file: %w", err)
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
		`SELECT id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type, created_at, updated_at, deleted_at, removed_locally, folder_size
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
		`SELECT id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type, created_at, updated_at, deleted_at, removed_locally, folder_size
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
		`UPDATE files SET content_hash=?, size=?, updated_at=?, change_rank=? WHERE id=? AND deleted_at IS NULL`,
		contentHash, size, now.Format(time.RFC3339Nano), d.nextChangeRank(), id,
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
		`SELECT id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type, created_at, updated_at, deleted_at, removed_locally, folder_size
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

// ListChangesByRank returns all files where change_rank > sinceRank for the given owner.
// Includes soft-deleted files so clients can handle deletions.
// Returns the files, the current max rank, and any error.
func (d *DB) ListChangesByRank(sinceRank int64, ownerID string) ([]File, int64, error) {
	// Get current max rank first.
	var currentRank int64
	d.db.QueryRow(`SELECT COALESCE(MAX(change_rank), 0) FROM files`).Scan(&currentRank)

	rows, err := d.db.Query(
		`SELECT id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type, created_at, updated_at, deleted_at, removed_locally, folder_size
		 FROM files WHERE owner_id = ? AND change_rank > ?
		 ORDER BY change_rank ASC`,
		ownerID, sinceRank,
	)
	if err != nil {
		return nil, 0, fmt.Errorf("metadata: list changes by rank: %w", err)
	}
	defer rows.Close()

	var files []File
	for rows.Next() {
		f, err := scanFileRow(rows)
		if err != nil {
			return nil, 0, err
		}
		files = append(files, *f)
	}
	return files, currentRank, rows.Err()
}

// TotalTrashSize returns the total size of all soft-deleted files.
func (d *DB) TotalTrashSize() int64 {
	var size int64
	d.db.QueryRow(`SELECT COALESCE(SUM(size), 0) FROM files WHERE deleted_at IS NOT NULL AND is_dir = 0`).Scan(&size)
	return size
}

// TotalVersionsSize returns the total size of all non-latest versions (old versions that retention may clean up).
func (d *DB) TotalVersionsSize() int64 {
	var size int64
	d.db.QueryRow(`SELECT COALESCE(SUM(v.size), 0) FROM versions v
		INNER JOIN (SELECT file_id, MAX(version_num) as max_v FROM versions GROUP BY file_id) m
		ON v.file_id = m.file_id AND v.version_num < m.max_v`).Scan(&size)
	return size
}

// TotalStorageUsed returns the total size of all non-deleted, non-directory files across all users.
func (d *DB) TotalStorageUsed() int64 {
	var size int64
	d.db.QueryRow(`SELECT COALESCE(SUM(size), 0) FROM files WHERE is_dir = 0 AND deleted_at IS NULL`).Scan(&size)
	return size
}

// StorageUsedByAllUsers returns storage used per user in a single query (avoids N+1).
func (d *DB) StorageUsedByAllUsers() map[string]int64 {
	result := make(map[string]int64)
	rows, err := d.db.Query(`SELECT owner_id, COALESCE(SUM(size), 0) FROM files WHERE is_dir = 0 AND deleted_at IS NULL GROUP BY owner_id`)
	if err != nil {
		return result
	}
	defer rows.Close()
	for rows.Next() {
		var uid string
		var size int64
		if rows.Scan(&uid, &size) == nil {
			result[uid] = size
		}
	}
	return result
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

// StorageCategory holds aggregated storage stats for a file type category.
type StorageCategory struct {
	Name       string `json:"name"`
	Count      int    `json:"count"`
	Size       int64  `json:"size"`
	Percentage float64 `json:"percentage"`
}

// StorageBreakdown returns storage usage grouped by file type category.
func (d *DB) StorageBreakdown() []StorageCategory {
	rows, err := d.db.Query(`SELECT COALESCE(mime_type, ''), COUNT(*), COALESCE(SUM(size), 0) FROM files WHERE is_dir = 0 AND deleted_at IS NULL GROUP BY mime_type`)
	if err != nil {
		return nil
	}
	defer rows.Close()

	// Aggregate by category
	catMap := map[string]StorageCategory{}
	var total int64
	for rows.Next() {
		var mime string
		var count int
		var size int64
		if rows.Scan(&mime, &count, &size) != nil {
			continue
		}
		cat := mimeToCategory(mime)
		entry := catMap[cat]
		entry.Name = cat
		entry.Count += count
		entry.Size += size
		catMap[cat] = entry
		total += size
	}

	// Convert to slice with percentages, sorted by size desc
	result := make([]StorageCategory, 0, len(catMap))
	for _, c := range catMap {
		if total > 0 {
			c.Percentage = float64(c.Size) / float64(total) * 100
		}
		result = append(result, c)
	}
	// Sort by size descending
	for i := 0; i < len(result); i++ {
		for j := i + 1; j < len(result); j++ {
			if result[j].Size > result[i].Size {
				result[i], result[j] = result[j], result[i]
			}
		}
	}
	return result
}

func mimeToCategory(mime string) string {
	switch {
	case strings.HasPrefix(mime, "video/"):
		return "Video"
	case strings.HasPrefix(mime, "image/"):
		return "Images"
	case strings.HasPrefix(mime, "audio/"):
		return "Audio"
	case strings.HasPrefix(mime, "text/"), strings.Contains(mime, "javascript"), strings.Contains(mime, "json"), strings.Contains(mime, "xml"), strings.Contains(mime, "yaml"):
		return "Code & Text"
	case strings.Contains(mime, "pdf"), strings.Contains(mime, "document"), strings.Contains(mime, "msword"), strings.Contains(mime, "presentation"), strings.Contains(mime, "spreadsheet"), strings.Contains(mime, "officedocument"):
		return "Documents"
	case strings.Contains(mime, "zip"), strings.Contains(mime, "compressed"), strings.Contains(mime, "archive"), strings.Contains(mime, "tar"), strings.Contains(mime, "gzip"):
		return "Archives"
	case mime == "" || mime == "application/octet-stream":
		return "Other"
	default:
		return "Other"
	}
}

// FolderSizeEntry holds a folder's ID, name, and total size of its contents.
type FolderSizeEntry struct {
	ID   string
	Name string
	Size int64
}

// ListTopFoldersBySize returns top-level folders ordered by total file size descending.
func (d *DB) ListTopFoldersBySize() ([]FolderSizeEntry, error) {
	// Use pre-computed folder_size column (recursive total) instead of joining children
	rows, err := d.db.Query(
		`SELECT id, name, folder_size
		 FROM files
		 WHERE is_dir = 1 AND parent_id IS NULL AND deleted_at IS NULL
		 ORDER BY folder_size DESC
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
		&f.FolderSize,
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
		&f.FolderSize,
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
	res, err := d.db.Exec(`UPDATE files SET removed_locally=1, change_rank=? WHERE id=?`, d.nextChangeRank(), fileID)
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
	res, err := d.db.Exec(`UPDATE files SET removed_locally=0, change_rank=? WHERE id=?`, d.nextChangeRank(), fileID)
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

// FileTreeEntry is a file with its relative path for tree listing.
type FileTreeEntry struct {
	ID           string
	Name         string
	RelativePath string
	IsDir        bool
	Size         int64
	ContentHash  sql.NullString
	RemovedLocally bool
}

// ListFilesRecursive returns all files (recursively) under a folder with relative paths.
// Uses a single recursive CTE query instead of N+1 queries per folder.
func (d *DB) ListFilesRecursive(folderID, ownerID string, isAdmin bool) ([]FileTreeEntry, error) {
	ownerFilter := ""
	args := []interface{}{folderID}
	if !isAdmin {
		ownerFilter = "AND owner_id = ?"
		args = append(args, ownerID)
	}

	query := fmt.Sprintf(`
		WITH RECURSIVE tree AS (
			SELECT id, name, is_dir, size, content_hash, removed_locally,
			       name as rel_path
			FROM files
			WHERE parent_id = ? AND deleted_at IS NULL %s
			UNION ALL
			SELECT f.id, f.name, f.is_dir, f.size, f.content_hash, f.removed_locally,
			       t.rel_path || '/' || f.name
			FROM files f JOIN tree t ON f.parent_id = t.id
			WHERE f.deleted_at IS NULL
		)
		SELECT id, name, rel_path, is_dir, size, content_hash, removed_locally
		FROM tree ORDER BY rel_path`, ownerFilter)

	rows, err := d.db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("metadata: list files recursive: %w", err)
	}
	defer rows.Close()

	var entries []FileTreeEntry
	for rows.Next() {
		var e FileTreeEntry
		var isDir, removedLocally int
		if err := rows.Scan(&e.ID, &e.Name, &e.RelativePath, &isDir, &e.Size, &e.ContentHash, &removedLocally); err != nil {
			return nil, fmt.Errorf("metadata: scan file tree entry: %w", err)
		}
		e.IsDir = isDir != 0
		e.RemovedLocally = removedLocally != 0
		entries = append(entries, e)
	}
	return entries, rows.Err()
}

// CheckHashes takes a list of content hashes and returns those that already exist in the database.
// Processes in batches of 500 to stay within SQLite's variable limit.
func (d *DB) CheckHashes(hashes []string) ([]string, error) {
	if len(hashes) == 0 {
		return nil, nil
	}

	var existing []string
	const batchSize = 500
	for start := 0; start < len(hashes); start += batchSize {
		end := start + batchSize
		if end > len(hashes) {
			end = len(hashes)
		}
		batch := hashes[start:end]

		placeholders := ""
		args := make([]interface{}, len(batch))
		for i, h := range batch {
			if i > 0 {
				placeholders += ","
			}
			placeholders += "?"
			args[i] = h
		}

		query := fmt.Sprintf("SELECT DISTINCT content_hash FROM files WHERE content_hash IN (%s) AND deleted_at IS NULL", placeholders)
		rows, err := d.db.Query(query, args...)
		if err != nil {
			return nil, fmt.Errorf("metadata: check hashes: %w", err)
		}
		for rows.Next() {
			var h string
			if err := rows.Scan(&h); err != nil {
				rows.Close()
				return nil, err
			}
			existing = append(existing, h)
		}
		rows.Close()
	}
	return existing, nil
}

// CheckFileHashes takes a list of content hashes and an ownerID, and returns a map of
// hash -> exists for all requested hashes. Only non-deleted files owned by ownerID are considered.
// Processes in batches of 500 to stay within SQLite's variable limit.
func (d *DB) CheckFileHashes(ownerID string, hashes []string) (map[string]bool, error) {
	result := make(map[string]bool, len(hashes))
	for _, h := range hashes {
		result[h] = false
	}
	if len(hashes) == 0 {
		return result, nil
	}

	const batchSize = 500
	for start := 0; start < len(hashes); start += batchSize {
		end := start + batchSize
		if end > len(hashes) {
			end = len(hashes)
		}
		batch := hashes[start:end]

		placeholders := ""
		args := make([]interface{}, 0, len(batch)+1)
		args = append(args, ownerID)
		for i, h := range batch {
			if i > 0 {
				placeholders += ","
			}
			placeholders += "?"
			args = append(args, h)
		}

		query := fmt.Sprintf("SELECT DISTINCT content_hash FROM files WHERE owner_id = ? AND content_hash IN (%s) AND deleted_at IS NULL", placeholders)
		rows, err := d.db.Query(query, args...)
		if err != nil {
			return nil, fmt.Errorf("metadata: check file hashes: %w", err)
		}

		for rows.Next() {
			var h string
			if err := rows.Scan(&h); err != nil {
				rows.Close()
				return nil, err
			}
			result[h] = true
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return nil, err
		}
	}
	return result, nil
}

// SearchFiles searches for files by name (case-insensitive LIKE match) for a given owner.
// Returns up to 50 results ordered by name.
func (d *DB) SearchFiles(ownerID, query string) ([]File, error) {
	rows, err := d.db.Query(
		`SELECT id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type, created_at, updated_at, deleted_at, removed_locally, folder_size
		 FROM files WHERE owner_id = ? AND name LIKE ? AND deleted_at IS NULL ORDER BY name LIMIT 50`,
		ownerID, "%"+query+"%",
	)
	if err != nil {
		return nil, err
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

// FileLock represents an active lock on a file.
type FileLock struct {
	FileID    string
	UserID    string
	Username  string
	Device    string
	LockedAt  time.Time
	ExpiresAt time.Time
}

// LockFile creates or refreshes a lock on a file. Returns an error if the file is locked by a different user.
func (d *DB) LockFile(fileID, userID, username, device string) (*FileLock, error) {
	// Check if already locked by someone else
	existing, _ := d.GetFileLock(fileID)
	if existing != nil && existing.UserID != userID && existing.ExpiresAt.After(time.Now()) {
		return nil, fmt.Errorf("file locked by %s", existing.Username)
	}

	now := time.Now()
	expires := now.Add(30 * time.Minute)

	d.db.Exec("DELETE FROM file_locks WHERE file_id = ?", fileID)
	_, err := d.db.Exec(
		"INSERT INTO file_locks (file_id, user_id, username, device, locked_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)",
		fileID, userID, username, device, now.Format(time.RFC3339), expires.Format(time.RFC3339),
	)
	if err != nil {
		return nil, fmt.Errorf("metadata: lock file: %w", err)
	}

	return &FileLock{FileID: fileID, UserID: userID, Username: username, Device: device, LockedAt: now, ExpiresAt: expires}, nil
}

// UnlockFile removes a lock on a file for a given user.
func (d *DB) UnlockFile(fileID, userID string) error {
	_, err := d.db.Exec("DELETE FROM file_locks WHERE file_id = ? AND user_id = ?", fileID, userID)
	return err
}

// GetFileLock returns the current lock on a file, or nil if not locked.
// Expired locks are cleaned up automatically.
func (d *DB) GetFileLock(fileID string) (*FileLock, error) {
	// Clean expired first
	d.db.Exec("DELETE FROM file_locks WHERE expires_at < ?", time.Now().Format(time.RFC3339))

	row := d.db.QueryRow(
		"SELECT file_id, user_id, username, device, locked_at, expires_at FROM file_locks WHERE file_id = ?",
		fileID,
	)
	var lock FileLock
	var lockedAt, expiresAt string
	err := row.Scan(&lock.FileID, &lock.UserID, &lock.Username, &lock.Device, &lockedAt, &expiresAt)
	if err != nil {
		return nil, err
	}
	lock.LockedAt, _ = time.Parse(time.RFC3339, lockedAt)
	lock.ExpiresAt, _ = time.Parse(time.RFC3339, expiresAt)
	return &lock, nil
}

// GetChangesSince returns the count of files changed since the given timestamp for a user.
// Used by SSE to notify clients of remote changes.
func (d *DB) GetChangesSince(userID string, since time.Time) ([]File, error) {
	return d.ListChangedFiles(since, userID)
}

// CleanupOldTrash permanently deletes files (and their versions/blocks/share_links)
// that have been in the trash longer than maxAgeDays days.
// Returns the total number of files removed.
func (d *DB) CleanupOldTrash(maxAgeDays int) (int64, error) {
	cutoff := time.Now().UTC().Add(-time.Duration(maxAgeDays) * 24 * time.Hour)
	cutoffStr := cutoff.Format(time.RFC3339)

	// Temporarily disable FK constraints so we can delete in the right order
	// without cascading issues.
	d.db.Exec(`PRAGMA foreign_keys=OFF`)
	defer d.db.Exec(`PRAGMA foreign_keys=ON`)

	// Delete dependent rows first.
	d.db.Exec(`DELETE FROM versions WHERE file_id IN (SELECT id FROM files WHERE deleted_at IS NOT NULL AND deleted_at < ?)`, cutoffStr)
	d.db.Exec(`DELETE FROM file_blocks WHERE file_id IN (SELECT id FROM files WHERE deleted_at IS NOT NULL AND deleted_at < ?)`, cutoffStr)
	d.db.Exec(`DELETE FROM share_links WHERE file_id IN (SELECT id FROM files WHERE deleted_at IS NOT NULL AND deleted_at < ?)`, cutoffStr)

	// Delete non-directory files first.
	res, _ := d.db.Exec(`DELETE FROM files WHERE deleted_at IS NOT NULL AND deleted_at < ? AND is_dir = 0`, cutoffStr)
	total, _ := res.RowsAffected()

	// Delete directories leaf-first (up to 50 rounds to handle deep nesting).
	for i := 0; i < 50; i++ {
		res, _ = d.db.Exec(`DELETE FROM files WHERE deleted_at IS NOT NULL AND deleted_at < ? AND is_dir = 1 AND id NOT IN (SELECT DISTINCT parent_id FROM files WHERE parent_id IS NOT NULL)`, cutoffStr)
		n, _ := res.RowsAffected()
		total += n
		if n == 0 {
			break
		}
	}

	return total, nil
}
