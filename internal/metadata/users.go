package metadata

import (
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

// User represents a SyncVault user account.
type User struct {
	ID         string
	Username   string
	Email      string
	Password   string
	Role       string
	QuotaBytes int64
	CreatedAt  time.Time
	UpdatedAt  time.Time
}

// ErrUserNotFound is returned when a user cannot be found.
var ErrUserNotFound = errors.New("metadata: user not found")

// ErrDuplicateUser is returned when creating a user with a conflicting username or email.
var ErrDuplicateUser = errors.New("metadata: duplicate username or email")

// CreateUser inserts a new user and returns the created User.
func (d *DB) CreateUser(username, email, password, role string) (*User, error) {
	now := time.Now().UTC()
	u := &User{
		ID:        uuid.New().String(),
		Username:  username,
		Email:     email,
		Password:  password,
		Role:      role,
		CreatedAt: now,
		UpdatedAt: now,
	}

	_, err := d.db.Exec(
		`INSERT INTO users (id, username, email, password, role, quota_bytes, created_at, updated_at)
		 VALUES (?, ?, ?, ?, ?, 0, ?, ?)`,
		u.ID, u.Username, u.Email, u.Password, u.Role,
		u.CreatedAt.Format(time.RFC3339Nano),
		u.UpdatedAt.Format(time.RFC3339Nano),
	)
	if err != nil {
		if isSQLiteConstraint(err) {
			return nil, ErrDuplicateUser
		}
		return nil, fmt.Errorf("metadata: create user: %w", err)
	}
	return u, nil
}

// GetUserByID returns the user with the given ID.
func (d *DB) GetUserByID(id string) (*User, error) {
	return d.scanUser(d.db.QueryRow(
		`SELECT id, username, email, password, role, quota_bytes, created_at, updated_at
		 FROM users WHERE id = ?`, id,
	))
}

// GetUserByUsername returns the user with the given username.
func (d *DB) GetUserByUsername(username string) (*User, error) {
	return d.scanUser(d.db.QueryRow(
		`SELECT id, username, email, password, role, quota_bytes, created_at, updated_at
		 FROM users WHERE username = ?`, username,
	))
}

// ListUsers returns all users in the database.
func (d *DB) ListUsers() ([]User, error) {
	rows, err := d.db.Query(
		`SELECT id, username, email, password, role, quota_bytes, created_at, updated_at
		 FROM users ORDER BY username`,
	)
	if err != nil {
		return nil, fmt.Errorf("metadata: list users: %w", err)
	}
	defer rows.Close()

	var users []User
	for rows.Next() {
		u, err := d.scanUserRow(rows)
		if err != nil {
			return nil, err
		}
		users = append(users, *u)
	}
	return users, rows.Err()
}

// UpdateUser updates the mutable fields of an existing user.
func (d *DB) UpdateUser(user *User) error {
	user.UpdatedAt = time.Now().UTC()
	res, err := d.db.Exec(
		`UPDATE users SET username=?, email=?, password=?, role=?, quota_bytes=?, updated_at=?
		 WHERE id=?`,
		user.Username, user.Email, user.Password, user.Role, user.QuotaBytes,
		user.UpdatedAt.Format(time.RFC3339Nano),
		user.ID,
	)
	if err != nil {
		if isSQLiteConstraint(err) {
			return ErrDuplicateUser
		}
		return fmt.Errorf("metadata: update user: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrUserNotFound
	}
	return nil
}

// DeleteUser removes the user with the given ID.
func (d *DB) DeleteUser(id string) error {
	res, err := d.db.Exec(`DELETE FROM users WHERE id=?`, id)
	if err != nil {
		return fmt.Errorf("metadata: delete user: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrUserNotFound
	}
	return nil
}

// scanUser scans a single user from a *sql.Row.
func (d *DB) scanUser(row *sql.Row) (*User, error) {
	var u User
	var createdAt, updatedAt string
	err := row.Scan(&u.ID, &u.Username, &u.Email, &u.Password, &u.Role,
		&u.QuotaBytes, &createdAt, &updatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrUserNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("metadata: scan user: %w", err)
	}
	u.CreatedAt, _ = time.Parse(time.RFC3339Nano, createdAt)
	u.UpdatedAt, _ = time.Parse(time.RFC3339Nano, updatedAt)
	return &u, nil
}

// scanUserRow scans a single user from *sql.Rows.
func (d *DB) scanUserRow(rows *sql.Rows) (*User, error) {
	var u User
	var createdAt, updatedAt string
	err := rows.Scan(&u.ID, &u.Username, &u.Email, &u.Password, &u.Role,
		&u.QuotaBytes, &createdAt, &updatedAt)
	if err != nil {
		return nil, fmt.Errorf("metadata: scan user row: %w", err)
	}
	u.CreatedAt, _ = time.Parse(time.RFC3339Nano, createdAt)
	u.UpdatedAt, _ = time.Parse(time.RFC3339Nano, updatedAt)
	return &u, nil
}

// isSQLiteConstraint returns true if the error is a SQLite constraint violation.
func isSQLiteConstraint(err error) bool {
	if err == nil {
		return false
	}
	// modernc.org/sqlite surfaces constraint errors with code 19 (SQLITE_CONSTRAINT).
	// We check the error message as a portable fallback.
	s := err.Error()
	return contains(s, "UNIQUE constraint failed") || contains(s, "constraint failed")
}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (s == sub || len(s) > 0 && containsStr(s, sub))
}

func containsStr(s, sub string) bool {
	for i := 0; i <= len(s)-len(sub); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
