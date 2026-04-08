package metadata

import (
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

// ShareLink represents a public (optionally password-protected) link to a file.
type ShareLink struct {
	ID            string
	FileID        string
	Token         string
	PasswordHash  string
	ExpiresAt     *time.Time
	MaxDownloads  int
	DownloadCount int
	CreatedBy     string
	CreatedAt     time.Time
}

// ErrShareLinkNotFound is returned when a share link cannot be found.
var ErrShareLinkNotFound = errors.New("metadata: share link not found")

// generateToken generates a random 16-byte URL-safe base64 token (no padding).
func generateToken() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("metadata: generate token: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// CreateShareLink creates a new share link for the given file.
// passwordHash may be empty for links without password protection.
// expiresAt may be nil for links that do not expire.
// maxDownloads may be 0 for unlimited downloads.
func (d *DB) CreateShareLink(fileID, createdBy, passwordHash string, expiresAt *time.Time, maxDownloads int) (*ShareLink, error) {
	token, err := generateToken()
	if err != nil {
		return nil, err
	}

	now := time.Now().UTC()
	sl := &ShareLink{
		ID:           uuid.New().String(),
		FileID:       fileID,
		Token:        token,
		PasswordHash: passwordHash,
		ExpiresAt:    expiresAt,
		MaxDownloads: maxDownloads,
		CreatedBy:    createdBy,
		CreatedAt:    now,
	}

	var expiresAtVal interface{}
	if expiresAt != nil {
		expiresAtVal = expiresAt.UTC().Format(time.RFC3339Nano)
	}

	var passwordHashVal interface{}
	if passwordHash != "" {
		passwordHashVal = passwordHash
	}

	var maxDownloadsVal interface{}
	if maxDownloads > 0 {
		maxDownloadsVal = maxDownloads
	}

	_, err = d.db.Exec(
		`INSERT INTO share_links (id, file_id, token, password_hash, expires_at, max_downloads, download_count, created_by, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)`,
		sl.ID, sl.FileID, sl.Token, passwordHashVal, expiresAtVal, maxDownloadsVal,
		sl.CreatedBy, sl.CreatedAt.Format(time.RFC3339Nano),
	)
	if err != nil {
		return nil, fmt.Errorf("metadata: create share link: %w", err)
	}
	return sl, nil
}

// GetShareLinkByToken returns the share link with the given token.
func (d *DB) GetShareLinkByToken(token string) (*ShareLink, error) {
	row := d.db.QueryRow(
		`SELECT id, file_id, token, password_hash, expires_at, max_downloads, download_count, created_by, created_at
		 FROM share_links WHERE token = ?`, token,
	)
	return scanShareLink(row)
}

// ListShareLinks returns all share links for the given file ID, newest first.
func (d *DB) ListShareLinks(fileID string) ([]ShareLink, error) {
	rows, err := d.db.Query(
		`SELECT id, file_id, token, password_hash, expires_at, max_downloads, download_count, created_by, created_at
		 FROM share_links WHERE file_id = ? ORDER BY created_at DESC`,
		fileID,
	)
	if err != nil {
		return nil, fmt.Errorf("metadata: list share links: %w", err)
	}
	defer rows.Close()

	var links []ShareLink
	for rows.Next() {
		sl, err := scanShareLinkRow(rows)
		if err != nil {
			return nil, err
		}
		links = append(links, *sl)
	}
	return links, rows.Err()
}

// IncrementShareDownload increments the download_count for the share link with the given ID.
func (d *DB) IncrementShareDownload(id string) error {
	res, err := d.db.Exec(
		`UPDATE share_links SET download_count = download_count + 1 WHERE id = ?`, id,
	)
	if err != nil {
		return fmt.Errorf("metadata: increment share download: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrShareLinkNotFound
	}
	return nil
}

// DeleteShareLink removes the share link with the given ID.
func (d *DB) DeleteShareLink(id string) error {
	res, err := d.db.Exec(`DELETE FROM share_links WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("metadata: delete share link: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrShareLinkNotFound
	}
	return nil
}

// SetShareLinkDisabled enables or disables a share link by setting expires_at.
// When disabled, expires_at is set to Unix epoch (1970-01-01); when enabled, it is cleared.
func (d *DB) SetShareLinkDisabled(id string, disabled bool) error {
	var err error
	if disabled {
		epoch := time.Unix(0, 0).UTC().Format(time.RFC3339Nano)
		_, err = d.db.Exec(`UPDATE share_links SET expires_at = ? WHERE id = ?`, epoch, id)
	} else {
		_, err = d.db.Exec(`UPDATE share_links SET expires_at = NULL WHERE id = ?`, id)
	}
	if err != nil {
		return fmt.Errorf("metadata: set share link disabled: %w", err)
	}
	return nil
}

// scanShareLink scans a single ShareLink from a *sql.Row.
func scanShareLink(row *sql.Row) (*ShareLink, error) {
	var sl ShareLink
	var passwordHash sql.NullString
	var expiresAt sql.NullString
	var maxDownloads sql.NullInt64
	var createdAt string

	err := row.Scan(
		&sl.ID, &sl.FileID, &sl.Token, &passwordHash,
		&expiresAt, &maxDownloads, &sl.DownloadCount,
		&sl.CreatedBy, &createdAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrShareLinkNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("metadata: scan share link: %w", err)
	}

	if passwordHash.Valid {
		sl.PasswordHash = passwordHash.String
	}
	if expiresAt.Valid {
		t, _ := time.Parse(time.RFC3339Nano, expiresAt.String)
		sl.ExpiresAt = &t
	}
	if maxDownloads.Valid {
		sl.MaxDownloads = int(maxDownloads.Int64)
	}
	sl.CreatedAt, _ = time.Parse(time.RFC3339Nano, createdAt)
	return &sl, nil
}

// ListShareLinksByUser returns all share links created by the given user, newest first.
func (d *DB) ListShareLinksByUser(userID string) ([]ShareLink, error) {
	rows, err := d.db.Query(
		`SELECT id, file_id, token, password_hash, expires_at, max_downloads, download_count, created_by, created_at
		 FROM share_links WHERE created_by = ? ORDER BY created_at DESC`,
		userID,
	)
	if err != nil {
		return nil, fmt.Errorf("metadata: list share links by user: %w", err)
	}
	defer rows.Close()

	var links []ShareLink
	for rows.Next() {
		sl, err := scanShareLinkRow(rows)
		if err != nil {
			return nil, err
		}
		links = append(links, *sl)
	}
	return links, rows.Err()
}

// GetShareLinkByID returns the share link with the given ID.
func (d *DB) GetShareLinkByID(id string) (*ShareLink, error) {
	row := d.db.QueryRow(
		`SELECT id, file_id, token, password_hash, expires_at, max_downloads, download_count, created_by, created_at
		 FROM share_links WHERE id = ?`, id,
	)
	return scanShareLink(row)
}

// scanShareLinkRow scans a single ShareLink from *sql.Rows.
func scanShareLinkRow(rows *sql.Rows) (*ShareLink, error) {
	var sl ShareLink
	var passwordHash sql.NullString
	var expiresAt sql.NullString
	var maxDownloads sql.NullInt64
	var createdAt string

	err := rows.Scan(
		&sl.ID, &sl.FileID, &sl.Token, &passwordHash,
		&expiresAt, &maxDownloads, &sl.DownloadCount,
		&sl.CreatedBy, &createdAt,
	)
	if err != nil {
		return nil, fmt.Errorf("metadata: scan share link row: %w", err)
	}

	if passwordHash.Valid {
		sl.PasswordHash = passwordHash.String
	}
	if expiresAt.Valid {
		t, _ := time.Parse(time.RFC3339Nano, expiresAt.String)
		sl.ExpiresAt = &t
	}
	if maxDownloads.Valid {
		sl.MaxDownloads = int(maxDownloads.Int64)
	}
	sl.CreatedAt, _ = time.Parse(time.RFC3339Nano, createdAt)
	return &sl, nil
}
