package metadata

import (
	"fmt"
	"time"

	"github.com/google/uuid"
)

type Notification struct {
	ID        string    `json:"id"`
	UserID    string    `json:"user_id"`
	Type      string    `json:"type"`
	Title     string    `json:"title"`
	Message   string    `json:"message"`
	Data      string    `json:"data,omitempty"`
	Read      bool      `json:"read"`
	Acted     bool      `json:"acted"`
	CreatedAt time.Time `json:"created_at"`
}

func (d *DB) CreateNotification(userID, ntype, title, message, data string) (*Notification, error) {
	n := &Notification{
		ID:        uuid.NewString(),
		UserID:    userID,
		Type:      ntype,
		Title:     title,
		Message:   message,
		Data:      data,
		CreatedAt: time.Now().UTC(),
	}
	_, err := d.db.Exec(
		`INSERT INTO notifications (id, user_id, type, title, message, data, read, acted, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?)`,
		n.ID, n.UserID, n.Type, n.Title, n.Message, n.Data, n.CreatedAt.Format(time.RFC3339Nano))
	if err != nil {
		return nil, fmt.Errorf("metadata: create notification: %w", err)
	}
	return n, nil
}

func (d *DB) ListNotifications(userID string) ([]Notification, error) {
	rows, err := d.db.Query(
		`SELECT id, user_id, type, title, message, COALESCE(data,''), read, acted, created_at
		 FROM notifications WHERE user_id = ? ORDER BY created_at DESC LIMIT 50`, userID)
	if err != nil {
		return nil, fmt.Errorf("metadata: list notifications: %w", err)
	}
	defer rows.Close()

	var result []Notification
	for rows.Next() {
		var n Notification
		var readInt, actedInt int
		var createdAt string
		if err := rows.Scan(&n.ID, &n.UserID, &n.Type, &n.Title, &n.Message, &n.Data, &readInt, &actedInt, &createdAt); err != nil {
			return nil, err
		}
		n.Read = readInt != 0
		n.Acted = actedInt != 0
		n.CreatedAt, _ = time.Parse(time.RFC3339Nano, createdAt)
		result = append(result, n)
	}
	return result, rows.Err()
}

func (d *DB) CountUnreadNotifications(userID string) (int, error) {
	var count int
	err := d.db.QueryRow(`SELECT COUNT(*) FROM notifications WHERE user_id = ? AND read = 0`, userID).Scan(&count)
	return count, err
}

func (d *DB) MarkNotificationActed(id string) error {
	_, err := d.db.Exec(`UPDATE notifications SET read = 1, acted = 1 WHERE id = ?`, id)
	return err
}

func (d *DB) MarkAllNotificationsRead(userID string) error {
	_, err := d.db.Exec(`UPDATE notifications SET read = 1 WHERE user_id = ?`, userID)
	return err
}

func (d *DB) GetNotification(id string) (*Notification, error) {
	var n Notification
	var readInt, actedInt int
	var createdAt string
	err := d.db.QueryRow(
		`SELECT id, user_id, type, title, message, COALESCE(data,''), read, acted, created_at
		 FROM notifications WHERE id = ?`, id).Scan(
		&n.ID, &n.UserID, &n.Type, &n.Title, &n.Message, &n.Data, &readInt, &actedInt, &createdAt)
	if err != nil {
		return nil, err
	}
	n.Read = readInt != 0
	n.Acted = actedInt != 0
	n.CreatedAt, _ = time.Parse(time.RFC3339Nano, createdAt)
	return &n, nil
}
