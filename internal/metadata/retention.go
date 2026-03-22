package metadata

import (
	"database/sql"
	"fmt"

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
