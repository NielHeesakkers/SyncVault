package metadata

import (
	"testing"
	"time"
)

func TestLogActivity(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "alice_act")

	err := db.LogActivity(u.ID, "upload", "file", "file-123", "uploaded doc.txt", "192.168.1.1")
	if err != nil {
		t.Fatalf("LogActivity: %v", err)
	}

	entries, err := db.QueryActivity(ActivityQuery{})
	if err != nil {
		t.Fatalf("QueryActivity: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("len(entries) = %d, want 1", len(entries))
	}
	e := entries[0]
	if e.ID == "" {
		t.Error("expected non-empty ID")
	}
	if e.UserID != u.ID {
		t.Errorf("UserID = %q, want %q", e.UserID, u.ID)
	}
	if e.Action != "upload" {
		t.Errorf("Action = %q, want upload", e.Action)
	}
	if e.Resource != "file" {
		t.Errorf("Resource = %q, want file", e.Resource)
	}
	if e.ResourceID != "file-123" {
		t.Errorf("ResourceID = %q, want file-123", e.ResourceID)
	}
	if e.Details != "uploaded doc.txt" {
		t.Errorf("Details = %q, want 'uploaded doc.txt'", e.Details)
	}
	if e.IPAddress != "192.168.1.1" {
		t.Errorf("IPAddress = %q, want 192.168.1.1", e.IPAddress)
	}
}

func TestLogActivity_NullableFields(t *testing.T) {
	db := openTestDB(t)

	// Empty strings for optional fields should store as NULL.
	err := db.LogActivity("", "system_start", "", "", "", "")
	if err != nil {
		t.Fatalf("LogActivity (no user): %v", err)
	}

	entries, err := db.QueryActivity(ActivityQuery{})
	if err != nil {
		t.Fatalf("QueryActivity: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("len(entries) = %d, want 1", len(entries))
	}
	e := entries[0]
	if e.UserID != "" {
		t.Errorf("UserID = %q, want empty (was NULL)", e.UserID)
	}
}

func TestQueryActivity_All(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "bob_act")

	db.LogActivity(u.ID, "login", "session", "s1", "", "10.0.0.1")
	db.LogActivity(u.ID, "upload", "file", "f1", "", "10.0.0.1")
	db.LogActivity(u.ID, "download", "file", "f2", "", "10.0.0.2")

	entries, err := db.QueryActivity(ActivityQuery{})
	if err != nil {
		t.Fatalf("QueryActivity: %v", err)
	}
	if len(entries) != 3 {
		t.Fatalf("len(entries) = %d, want 3", len(entries))
	}
	// Newest first — download was last logged.
	if entries[0].Action != "download" {
		t.Errorf("entries[0].Action = %q, want download (newest first)", entries[0].Action)
	}
}

func TestQueryActivity_FilterByUser(t *testing.T) {
	db := openTestDB(t)
	u1 := mustCreateUser(t, db, "carol_act")
	u2 := mustCreateUser(t, db, "dave_act")

	db.LogActivity(u1.ID, "login", "", "", "", "")
	db.LogActivity(u2.ID, "login", "", "", "", "")
	db.LogActivity(u1.ID, "upload", "file", "f1", "", "")

	entries, err := db.QueryActivity(ActivityQuery{UserID: u1.ID})
	if err != nil {
		t.Fatalf("QueryActivity (filter user): %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("len(entries) = %d, want 2", len(entries))
	}
	for _, e := range entries {
		if e.UserID != u1.ID {
			t.Errorf("entry.UserID = %q, want %q", e.UserID, u1.ID)
		}
	}
}

func TestQueryActivity_FilterByAction(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "eve_act")

	db.LogActivity(u.ID, "login", "", "", "", "")
	db.LogActivity(u.ID, "upload", "file", "f1", "", "")
	db.LogActivity(u.ID, "upload", "file", "f2", "", "")
	db.LogActivity(u.ID, "download", "file", "f1", "", "")

	entries, err := db.QueryActivity(ActivityQuery{Action: "upload"})
	if err != nil {
		t.Fatalf("QueryActivity (filter action): %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("len(entries) = %d, want 2", len(entries))
	}
	for _, e := range entries {
		if e.Action != "upload" {
			t.Errorf("entry.Action = %q, want upload", e.Action)
		}
	}
}

func TestQueryActivity_FilterByDateRange(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "frank_act")

	// Log 3 events with deliberate ordering and then query by date.
	db.LogActivity(u.ID, "event_a", "", "", "", "")
	time.Sleep(5 * time.Millisecond)
	cutAfter := time.Now().UTC()
	time.Sleep(5 * time.Millisecond)
	db.LogActivity(u.ID, "event_b", "", "", "", "")
	time.Sleep(5 * time.Millisecond)
	db.LogActivity(u.ID, "event_c", "", "", "", "")
	time.Sleep(5 * time.Millisecond)
	cutBefore := time.Now().UTC()
	time.Sleep(5 * time.Millisecond)
	db.LogActivity(u.ID, "event_d", "", "", "", "")

	// Should return event_b and event_c (between cutAfter and cutBefore).
	entries, err := db.QueryActivity(ActivityQuery{After: &cutAfter, Before: &cutBefore})
	if err != nil {
		t.Fatalf("QueryActivity (date range): %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("len(entries) = %d, want 2", len(entries))
	}
	for _, e := range entries {
		if e.Action != "event_b" && e.Action != "event_c" {
			t.Errorf("unexpected action %q in date range results", e.Action)
		}
	}
}

func TestQueryActivity_LimitOffset(t *testing.T) {
	db := openTestDB(t)
	u := mustCreateUser(t, db, "grace_act")

	for i := 0; i < 10; i++ {
		db.LogActivity(u.ID, "event", "", "", "", "")
	}

	entries, err := db.QueryActivity(ActivityQuery{Limit: 3, Offset: 2})
	if err != nil {
		t.Fatalf("QueryActivity (limit/offset): %v", err)
	}
	if len(entries) != 3 {
		t.Errorf("len(entries) = %d, want 3", len(entries))
	}
}
