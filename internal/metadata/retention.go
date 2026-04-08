package metadata

import (
	"database/sql"
	"fmt"
	"log"
	"time"

	"github.com/google/uuid"
)

// RetentionPolicy defines how long versions are kept for a sync task.
type RetentionPolicy struct {
	ID            string `json:"id"`
	SyncTaskID    string `json:"sync_task_id"`
	HourlyHours   int    `json:"hourly_hours"`   // Keep hourly versions for N hours
	DailyDays     int    `json:"daily_days"`      // Keep daily versions for N days
	WeeklyWeeks   int    `json:"weekly_weeks"`    // Keep weekly versions for N weeks
	MonthlyMonths int    `json:"monthly_months"`  // Keep monthly versions for N months
	YearlyYears   int    `json:"yearly_years"`    // Keep yearly versions for N years
	MaxVersions   int    `json:"max_versions"`    // Hard cap on total versions (0 = unlimited)
}

// GetRetentionPolicy returns the retention policy for a sync task, or nil if none is set.
func (d *DB) GetRetentionPolicy(syncTaskID string) (*RetentionPolicy, error) {
	row := d.db.QueryRow(
		`SELECT id, sync_task_id, hourly_hours, daily_days, weekly_weeks, monthly_months, yearly_years, max_versions
		 FROM retention_policies WHERE sync_task_id = ?`, syncTaskID)

	var p RetentionPolicy
	err := row.Scan(&p.ID, &p.SyncTaskID, &p.HourlyHours, &p.DailyDays, &p.WeeklyWeeks, &p.MonthlyMonths, &p.YearlyYears, &p.MaxVersions)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("metadata: get retention policy: %w", err)
	}
	return &p, nil
}

// SetRetentionPolicy creates or updates the retention policy for a sync task.
func (d *DB) SetRetentionPolicy(p RetentionPolicy) error {
	if p.ID == "" {
		p.ID = uuid.NewString()
	}
	_, err := d.db.Exec(
		`INSERT INTO retention_policies (id, sync_task_id, hourly_hours, daily_days, weekly_weeks, monthly_months, yearly_years, max_versions)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		 ON CONFLICT(sync_task_id) DO UPDATE SET
		   hourly_hours = excluded.hourly_hours,
		   daily_days = excluded.daily_days,
		   weekly_weeks = excluded.weekly_weeks,
		   monthly_months = excluded.monthly_months,
		   yearly_years = excluded.yearly_years,
		   max_versions = excluded.max_versions`,
		p.ID, p.SyncTaskID, p.HourlyHours, p.DailyDays, p.WeeklyWeeks, p.MonthlyMonths, p.YearlyYears, p.MaxVersions)
	if err != nil {
		return fmt.Errorf("metadata: set retention policy: %w", err)
	}
	return nil
}

// DeleteRetentionPolicy removes the retention policy for a sync task.
func (d *DB) DeleteRetentionPolicy(syncTaskID string) error {
	_, err := d.db.Exec(`DELETE FROM retention_policies WHERE sync_task_id = ?`, syncTaskID)
	if err != nil {
		return fmt.Errorf("metadata: delete retention policy: %w", err)
	}
	return nil
}

// EnforceRetentionPolicy applies Smart Retention logic for a single task.
// It determines which versions to keep based on the policy rules and deletes the rest.
// Returns the number of versions deleted.
func (d *DB) EnforceRetentionPolicy(taskID string, policy RetentionPolicy) (int, error) {
	// Get the task's folder_id.
	var folderID string
	err := d.db.QueryRow(`SELECT folder_id FROM sync_tasks WHERE id = ?`, taskID).Scan(&folderID)
	if err != nil {
		return 0, fmt.Errorf("metadata: enforce retention: get folder: %w", err)
	}

	// Get all non-directory file IDs under this folder recursively.
	rows, err := d.db.Query(`
		WITH RECURSIVE tree AS (
			SELECT id, is_dir FROM files WHERE parent_id = ? AND deleted_at IS NULL
			UNION ALL
			SELECT f.id, f.is_dir FROM files f JOIN tree t ON f.parent_id = t.id WHERE f.deleted_at IS NULL
		)
		SELECT id FROM tree WHERE is_dir = 0`, folderID)
	if err != nil {
		return 0, fmt.Errorf("metadata: enforce retention: list files: %w", err)
	}
	defer rows.Close()

	var fileIDs []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return 0, fmt.Errorf("metadata: enforce retention: scan file: %w", err)
		}
		fileIDs = append(fileIDs, id)
	}
	if err := rows.Err(); err != nil {
		return 0, fmt.Errorf("metadata: enforce retention: rows err: %w", err)
	}

	now := time.Now().UTC()
	totalDeleted := 0

	for _, fileID := range fileIDs {
		deleted, err := d.enforceRetentionForFile(fileID, policy, now)
		if err != nil {
			log.Printf("metadata: enforce retention for file %s: %v", fileID, err)
			continue
		}
		totalDeleted += deleted
	}

	return totalDeleted, nil
}

// enforceRetentionForFile applies retention rules to a single file's versions.
func (d *DB) enforceRetentionForFile(fileID string, policy RetentionPolicy, now time.Time) (int, error) {
	// Get all versions sorted by created_at DESC.
	rows, err := d.db.Query(
		`SELECT id, created_at FROM versions WHERE file_id = ? ORDER BY created_at DESC`,
		fileID)
	if err != nil {
		return 0, err
	}
	defer rows.Close()

	type versionInfo struct {
		id        string
		createdAt time.Time
	}

	var versions []versionInfo
	for rows.Next() {
		var v versionInfo
		var createdStr string
		if err := rows.Scan(&v.id, &createdStr); err != nil {
			return 0, err
		}
		v.createdAt, _ = time.Parse(time.RFC3339Nano, createdStr)
		if v.createdAt.IsZero() {
			v.createdAt, _ = time.Parse("2006-01-02 15:04:05", createdStr)
		}
		versions = append(versions, v)
	}
	if err := rows.Err(); err != nil {
		return 0, err
	}

	if len(versions) <= 1 {
		return 0, nil // Always keep at least 1 version.
	}

	// Build the keep set.
	keepSet := make(map[string]bool)

	// Always keep the latest version (index 0, since sorted DESC).
	keepSet[versions[0].id] = true

	// Keep the latest max_versions versions.
	if policy.MaxVersions > 0 {
		for i := 0; i < len(versions) && i < policy.MaxVersions; i++ {
			keepSet[versions[i].id] = true
		}
	}

	// Keep the latest version per day for daily_days days.
	if policy.DailyDays > 0 {
		cutoff := now.AddDate(0, 0, -policy.DailyDays)
		seenDays := make(map[string]bool)
		for _, v := range versions {
			if v.createdAt.Before(cutoff) {
				continue
			}
			dayKey := v.createdAt.Format("2006-01-02")
			if !seenDays[dayKey] {
				seenDays[dayKey] = true
				keepSet[v.id] = true
			}
		}
	}

	// Keep the latest version per week for weekly_weeks weeks.
	if policy.WeeklyWeeks > 0 {
		cutoff := now.AddDate(0, 0, -policy.WeeklyWeeks*7)
		seenWeeks := make(map[string]bool)
		for _, v := range versions {
			if v.createdAt.Before(cutoff) {
				continue
			}
			year, week := v.createdAt.ISOWeek()
			weekKey := fmt.Sprintf("%d-W%02d", year, week)
			if !seenWeeks[weekKey] {
				seenWeeks[weekKey] = true
				keepSet[v.id] = true
			}
		}
	}

	// Keep the latest version per month for monthly_months months.
	if policy.MonthlyMonths > 0 {
		cutoff := now.AddDate(0, -policy.MonthlyMonths, 0)
		seenMonths := make(map[string]bool)
		for _, v := range versions {
			if v.createdAt.Before(cutoff) {
				continue
			}
			monthKey := v.createdAt.Format("2006-01")
			if !seenMonths[monthKey] {
				seenMonths[monthKey] = true
				keepSet[v.id] = true
			}
		}
	}

	// Keep the latest version per year for yearly_years years.
	if policy.YearlyYears > 0 {
		cutoff := now.AddDate(-policy.YearlyYears, 0, 0)
		seenYears := make(map[string]bool)
		for _, v := range versions {
			if v.createdAt.Before(cutoff) {
				continue
			}
			yearKey := v.createdAt.Format("2006")
			if !seenYears[yearKey] {
				seenYears[yearKey] = true
				keepSet[v.id] = true
			}
		}
	}

	// Delete versions not in the keep set.
	deleted := 0
	for _, v := range versions {
		if keepSet[v.id] {
			continue
		}
		// Delete associated file_blocks first, then the version.
		d.db.Exec(`DELETE FROM file_blocks WHERE file_id = ? AND version_num = (SELECT version_num FROM versions WHERE id = ?)`, fileID, v.id)
		_, err := d.db.Exec(`DELETE FROM versions WHERE id = ?`, v.id)
		if err != nil {
			log.Printf("metadata: enforce retention: delete version %s: %v", v.id, err)
			continue
		}
		deleted++
	}

	return deleted, nil
}

// EnforceAllRetentionPolicies enforces retention policies for all tasks that have one.
func (d *DB) EnforceAllRetentionPolicies() {
	rows, err := d.db.Query(`
		SELECT rp.sync_task_id, rp.daily_days, rp.weekly_weeks, rp.monthly_months,
		       rp.yearly_years, rp.hourly_hours, rp.max_versions
		FROM retention_policies rp
		JOIN sync_tasks st ON st.id = rp.sync_task_id`)
	if err != nil {
		log.Printf("metadata: enforce all retention policies: %v", err)
		return
	}
	defer rows.Close()

	type taskPolicy struct {
		taskID string
		policy RetentionPolicy
	}
	var policies []taskPolicy

	for rows.Next() {
		var tp taskPolicy
		if err := rows.Scan(&tp.taskID, &tp.policy.DailyDays, &tp.policy.WeeklyWeeks,
			&tp.policy.MonthlyMonths, &tp.policy.YearlyYears, &tp.policy.HourlyHours,
			&tp.policy.MaxVersions); err != nil {
			log.Printf("metadata: enforce all retention: scan: %v", err)
			continue
		}
		policies = append(policies, tp)
	}

	for _, tp := range policies {
		deleted, err := d.EnforceRetentionPolicy(tp.taskID, tp.policy)
		if err != nil {
			log.Printf("metadata: enforce retention for task %s: %v", tp.taskID, err)
			continue
		}
		if deleted > 0 {
			log.Printf("metadata: retention enforcement deleted %d versions for task %s", deleted, tp.taskID)
		}
	}
}
