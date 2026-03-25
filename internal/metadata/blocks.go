package metadata

import (
	"fmt"
)

// FileBlock holds the rolling (weak) and strong hash for a single 256 KB block.
type FileBlock struct {
	FileID     string
	VersionNum int
	BlockIndex int
	WeakHash   uint32
	StrongHash string
}

// SaveFileBlocks inserts or replaces all block records for a given file version.
func (d *DB) SaveFileBlocks(blocks []FileBlock) error {
	if len(blocks) == 0 {
		return nil
	}
	tx, err := d.db.Begin()
	if err != nil {
		return fmt.Errorf("metadata: save file blocks begin tx: %w", err)
	}
	stmt, err := tx.Prepare(
		`INSERT OR REPLACE INTO file_blocks (file_id, version_num, block_index, weak_hash, strong_hash)
		 VALUES (?, ?, ?, ?, ?)`,
	)
	if err != nil {
		tx.Rollback()
		return fmt.Errorf("metadata: save file blocks prepare: %w", err)
	}
	defer stmt.Close()

	for _, b := range blocks {
		if _, err := stmt.Exec(b.FileID, b.VersionNum, b.BlockIndex, b.WeakHash, b.StrongHash); err != nil {
			tx.Rollback()
			return fmt.Errorf("metadata: save file block (file=%s, v=%d, idx=%d): %w", b.FileID, b.VersionNum, b.BlockIndex, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("metadata: save file blocks commit: %w", err)
	}
	return nil
}

// GetFileBlocks returns all block signatures for the given file at the given version,
// ordered by block_index ascending.
func (d *DB) GetFileBlocks(fileID string, versionNum int) ([]FileBlock, error) {
	rows, err := d.db.Query(
		`SELECT file_id, version_num, block_index, weak_hash, strong_hash
		 FROM file_blocks WHERE file_id = ? AND version_num = ?
		 ORDER BY block_index ASC`,
		fileID, versionNum,
	)
	if err != nil {
		return nil, fmt.Errorf("metadata: get file blocks: %w", err)
	}
	defer rows.Close()

	var blocks []FileBlock
	for rows.Next() {
		var b FileBlock
		if err := rows.Scan(&b.FileID, &b.VersionNum, &b.BlockIndex, &b.WeakHash, &b.StrongHash); err != nil {
			return nil, fmt.Errorf("metadata: scan file block: %w", err)
		}
		blocks = append(blocks, b)
	}
	return blocks, rows.Err()
}

// DeleteFileBlocks removes all block records for the given file and version.
func (d *DB) DeleteFileBlocks(fileID string, versionNum int) error {
	_, err := d.db.Exec(
		`DELETE FROM file_blocks WHERE file_id = ? AND version_num = ?`,
		fileID, versionNum,
	)
	if err != nil {
		return fmt.Errorf("metadata: delete file blocks: %w", err)
	}
	return nil
}
