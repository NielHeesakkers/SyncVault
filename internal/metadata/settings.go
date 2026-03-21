package metadata

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// ErrSettingNotFound is returned when a setting key does not exist.
var ErrSettingNotFound = errors.New("setting not found")

// GetSetting retrieves a single setting by key.
func (d *DB) GetSetting(key string) (string, error) {
	var value string
	err := d.db.QueryRow(`SELECT value FROM settings WHERE key = ?`, key).Scan(&value)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrSettingNotFound
	}
	if err != nil {
		return "", fmt.Errorf("metadata: get setting %q: %w", key, err)
	}
	return value, nil
}

// SetSetting inserts or updates a setting key-value pair.
func (d *DB) SetSetting(key, value string) error {
	_, err := d.db.Exec(
		`INSERT INTO settings(key, value) VALUES(?, ?)
		 ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
		key, value,
	)
	if err != nil {
		return fmt.Errorf("metadata: set setting %q: %w", key, err)
	}
	return nil
}

// GetAllSettings returns all settings as a map.
func (d *DB) GetAllSettings() (map[string]string, error) {
	rows, err := d.db.Query(`SELECT key, value FROM settings ORDER BY key`)
	if err != nil {
		return nil, fmt.Errorf("metadata: get all settings: %w", err)
	}
	defer rows.Close()

	result := make(map[string]string)
	for rows.Next() {
		var k, v string
		if err := rows.Scan(&k, &v); err != nil {
			return nil, fmt.Errorf("metadata: scan setting: %w", err)
		}
		result[k] = v
	}
	return result, rows.Err()
}

// GetSettingsWithPrefix returns all settings whose key starts with the given prefix.
func (d *DB) GetSettingsWithPrefix(prefix string) (map[string]string, error) {
	rows, err := d.db.Query(
		`SELECT key, value FROM settings WHERE key LIKE ? ORDER BY key`,
		strings.ReplaceAll(prefix, "%", "\\%")+"%",
	)
	if err != nil {
		return nil, fmt.Errorf("metadata: get settings with prefix %q: %w", prefix, err)
	}
	defer rows.Close()

	result := make(map[string]string)
	for rows.Next() {
		var k, v string
		if err := rows.Scan(&k, &v); err != nil {
			return nil, fmt.Errorf("metadata: scan setting: %w", err)
		}
		result[k] = v
	}
	return result, rows.Err()
}
