package metadata

import (
	"database/sql"
	"fmt"
	"time"

	"github.com/google/uuid"
)

// ActivityEntry represents a single entry in the activity log.
type ActivityEntry struct {
	ID         string    `json:"id"`
	UserID     string    `json:"user_id,omitempty"`
	Action     string    `json:"action"`
	Resource   string    `json:"resource,omitempty"`
	ResourceID string    `json:"resource_id,omitempty"`
	Details    string    `json:"details,omitempty"`
	IPAddress  string    `json:"ip_address,omitempty"`
	CreatedAt  time.Time `json:"created_at"`
}

// ActivityQuery holds the filter parameters for QueryActivity.
type ActivityQuery struct {
	UserID string
	Action string
	After  *time.Time
	Before *time.Time
	Limit  int
	Offset int
}

// LogActivity inserts a new entry into the activity_log table.
// All string fields except action may be empty; they are stored as NULL when empty.
func (d *DB) LogActivity(userID, action, resource, resourceID, details, ipAddress string) error {
	now := time.Now().UTC()
	id := uuid.New().String()

	var nullUserID, nullResource, nullResourceID, nullDetails, nullIPAddress interface{}
	if userID != "" {
		nullUserID = userID
	}
	if resource != "" {
		nullResource = resource
	}
	if resourceID != "" {
		nullResourceID = resourceID
	}
	if details != "" {
		nullDetails = details
	}
	if ipAddress != "" {
		nullIPAddress = ipAddress
	}

	_, err := d.db.Exec(
		`INSERT INTO activity_log (id, user_id, action, resource, resource_id, details, ip_address, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		id, nullUserID, action, nullResource, nullResourceID, nullDetails, nullIPAddress,
		now.Format(time.RFC3339Nano),
	)
	if err != nil {
		return fmt.Errorf("metadata: log activity: %w", err)
	}
	return nil
}

// QueryActivity returns activity log entries matching the query, newest first.
// Zero values for string fields mean "no filter". Limit <= 0 means no limit.
func (d *DB) QueryActivity(q ActivityQuery) ([]ActivityEntry, error) {
	query := `SELECT id, user_id, action, resource, resource_id, details, ip_address, created_at
	          FROM activity_log WHERE 1=1`
	args := []interface{}{}

	if q.UserID != "" {
		query += " AND user_id = ?"
		args = append(args, q.UserID)
	}
	if q.Action != "" {
		query += " AND action = ?"
		args = append(args, q.Action)
	}
	if q.After != nil {
		query += " AND created_at > ?"
		args = append(args, q.After.UTC().Format(time.RFC3339Nano))
	}
	if q.Before != nil {
		query += " AND created_at < ?"
		args = append(args, q.Before.UTC().Format(time.RFC3339Nano))
	}

	query += " ORDER BY created_at DESC"

	if q.Limit > 0 {
		query += fmt.Sprintf(" LIMIT %d", q.Limit)
	}
	if q.Offset > 0 {
		query += fmt.Sprintf(" OFFSET %d", q.Offset)
	}

	rows, err := d.db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("metadata: query activity: %w", err)
	}
	defer rows.Close()

	var entries []ActivityEntry
	for rows.Next() {
		e, err := scanActivityRow(rows)
		if err != nil {
			return nil, err
		}
		entries = append(entries, *e)
	}
	return entries, rows.Err()
}

// scanActivityRow scans a single ActivityEntry from *sql.Rows.
func scanActivityRow(rows *sql.Rows) (*ActivityEntry, error) {
	var e ActivityEntry
	var userID, resource, resourceID, details, ipAddress sql.NullString
	var createdAt string

	err := rows.Scan(
		&e.ID, &userID, &e.Action, &resource, &resourceID, &details, &ipAddress, &createdAt,
	)
	if err != nil {
		return nil, fmt.Errorf("metadata: scan activity row: %w", err)
	}
	if userID.Valid {
		e.UserID = userID.String
	}
	if resource.Valid {
		e.Resource = resource.String
	}
	if resourceID.Valid {
		e.ResourceID = resourceID.String
	}
	if details.Valid {
		e.Details = details.String
	}
	if ipAddress.Valid {
		e.IPAddress = ipAddress.String
	}
	e.CreatedAt, _ = time.Parse(time.RFC3339Nano, createdAt)
	return &e, nil
}
