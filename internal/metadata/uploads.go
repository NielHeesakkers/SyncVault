package metadata

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

// UploadSession holds state for a chunked upload in progress.
type UploadSession struct {
	ID             string
	UserID         string
	ParentID       sql.NullString
	Filename       string
	TotalSize      int64
	ChunkSize      int64
	TotalChunks    int
	ReceivedChunks []int
	CreatedAt      time.Time
	ExpiresAt      time.Time
}

// ErrUploadNotFound is returned when an upload session cannot be found.
var ErrUploadNotFound = errors.New("metadata: upload session not found")

// CreateUploadSession inserts a new upload session record.
func (d *DB) CreateUploadSession(userID, parentID, filename string, totalSize, chunkSize int64, totalChunks int) (*UploadSession, error) {
	now := time.Now().UTC()
	sess := &UploadSession{
		ID:             uuid.New().String(),
		UserID:         userID,
		Filename:       filename,
		TotalSize:      totalSize,
		ChunkSize:      chunkSize,
		TotalChunks:    totalChunks,
		ReceivedChunks: []int{},
		CreatedAt:      now,
		ExpiresAt:      now.Add(24 * time.Hour),
	}
	if parentID != "" {
		sess.ParentID = sql.NullString{String: parentID, Valid: true}
	}

	chunksJSON, _ := json.Marshal(sess.ReceivedChunks)

	_, err := d.db.Exec(
		`INSERT INTO upload_sessions (id, user_id, parent_id, filename, total_size, chunk_size, total_chunks, received_chunks, created_at, expires_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		sess.ID,
		sess.UserID,
		nullStringVal(sess.ParentID),
		sess.Filename,
		sess.TotalSize,
		sess.ChunkSize,
		sess.TotalChunks,
		string(chunksJSON),
		sess.CreatedAt.Format(time.RFC3339Nano),
		sess.ExpiresAt.Format(time.RFC3339Nano),
	)
	if err != nil {
		return nil, fmt.Errorf("metadata: create upload session: %w", err)
	}
	return sess, nil
}

// GetUploadSession returns the upload session with the given ID.
func (d *DB) GetUploadSession(id string) (*UploadSession, error) {
	row := d.db.QueryRow(
		`SELECT id, user_id, parent_id, filename, total_size, chunk_size, total_chunks, received_chunks, created_at, expires_at
		 FROM upload_sessions WHERE id = ?`, id,
	)
	return scanUploadSession(row)
}

// AddReceivedChunk records that chunk n has been received for the given upload session.
// Returns the updated session.
func (d *DB) AddReceivedChunk(id string, n int) (*UploadSession, error) {
	sess, err := d.GetUploadSession(id)
	if err != nil {
		return nil, err
	}

	// Deduplicate: only append if not already present.
	for _, c := range sess.ReceivedChunks {
		if c == n {
			return sess, nil
		}
	}
	sess.ReceivedChunks = append(sess.ReceivedChunks, n)

	chunksJSON, _ := json.Marshal(sess.ReceivedChunks)
	_, err = d.db.Exec(
		`UPDATE upload_sessions SET received_chunks = ? WHERE id = ?`,
		string(chunksJSON), id,
	)
	if err != nil {
		return nil, fmt.Errorf("metadata: add received chunk: %w", err)
	}
	sess.ReceivedChunks = sess.ReceivedChunks
	return sess, nil
}

// DeleteUploadSession removes the upload session record.
func (d *DB) DeleteUploadSession(id string) error {
	res, err := d.db.Exec(`DELETE FROM upload_sessions WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("metadata: delete upload session: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrUploadNotFound
	}
	return nil
}

// DeleteExpiredUploadSessions removes all upload sessions whose expires_at is in the past.
func (d *DB) DeleteExpiredUploadSessions() (int64, error) {
	now := time.Now().UTC().Format(time.RFC3339Nano)
	res, err := d.db.Exec(`DELETE FROM upload_sessions WHERE expires_at < ?`, now)
	if err != nil {
		return 0, fmt.Errorf("metadata: delete expired upload sessions: %w", err)
	}
	n, _ := res.RowsAffected()
	return n, nil
}

func scanUploadSession(row *sql.Row) (*UploadSession, error) {
	var s UploadSession
	var chunksJSON, createdAt, expiresAt string
	err := row.Scan(
		&s.ID, &s.UserID, &s.ParentID, &s.Filename,
		&s.TotalSize, &s.ChunkSize, &s.TotalChunks, &chunksJSON,
		&createdAt, &expiresAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrUploadNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("metadata: scan upload session: %w", err)
	}
	if err := json.Unmarshal([]byte(chunksJSON), &s.ReceivedChunks); err != nil {
		s.ReceivedChunks = []int{}
	}
	s.CreatedAt, _ = time.Parse(time.RFC3339Nano, createdAt)
	s.ExpiresAt, _ = time.Parse(time.RFC3339Nano, expiresAt)
	return &s, nil
}
