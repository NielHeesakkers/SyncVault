package metadata

import (
	"errors"
	"testing"
)

func TestCreateUser(t *testing.T) {
	db := openTestDB(t)
	u, err := db.CreateUser("alice", "alice@example.com", "hashed-pw", "user")
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	if u.ID == "" {
		t.Error("expected non-empty ID")
	}
	if u.Username != "alice" {
		t.Errorf("Username = %q, want %q", u.Username, "alice")
	}
	if u.Role != "user" {
		t.Errorf("Role = %q, want %q", u.Role, "user")
	}
}

func TestCreateUser_DuplicateUsername(t *testing.T) {
	db := openTestDB(t)
	if _, err := db.CreateUser("bob", "bob@example.com", "pw", "user"); err != nil {
		t.Fatal(err)
	}
	_, err := db.CreateUser("bob", "bob2@example.com", "pw", "user")
	if !errors.Is(err, ErrDuplicateUser) {
		t.Errorf("expected ErrDuplicateUser, got %v", err)
	}
}

func TestCreateUser_DuplicateEmail(t *testing.T) {
	db := openTestDB(t)
	if _, err := db.CreateUser("carol", "carol@example.com", "pw", "user"); err != nil {
		t.Fatal(err)
	}
	_, err := db.CreateUser("carol2", "carol@example.com", "pw", "user")
	if !errors.Is(err, ErrDuplicateUser) {
		t.Errorf("expected ErrDuplicateUser, got %v", err)
	}
}

func TestGetUserByID(t *testing.T) {
	db := openTestDB(t)
	created, _ := db.CreateUser("dave", "dave@example.com", "pw", "admin")
	got, err := db.GetUserByID(created.ID)
	if err != nil {
		t.Fatalf("GetUserByID: %v", err)
	}
	if got.Username != "dave" {
		t.Errorf("Username = %q, want %q", got.Username, "dave")
	}
}

func TestGetUserByID_NotFound(t *testing.T) {
	db := openTestDB(t)
	_, err := db.GetUserByID("nonexistent")
	if !errors.Is(err, ErrUserNotFound) {
		t.Errorf("expected ErrUserNotFound, got %v", err)
	}
}

func TestGetUserByUsername(t *testing.T) {
	db := openTestDB(t)
	db.CreateUser("eve", "eve@example.com", "pw", "user")
	got, err := db.GetUserByUsername("eve")
	if err != nil {
		t.Fatalf("GetUserByUsername: %v", err)
	}
	if got.Email != "eve@example.com" {
		t.Errorf("Email = %q, want %q", got.Email, "eve@example.com")
	}
}

func TestListUsers(t *testing.T) {
	db := openTestDB(t)
	db.CreateUser("frank", "frank@example.com", "pw", "user")
	db.CreateUser("grace", "grace@example.com", "pw", "admin")

	users, err := db.ListUsers()
	if err != nil {
		t.Fatalf("ListUsers: %v", err)
	}
	if len(users) != 2 {
		t.Errorf("len(users) = %d, want 2", len(users))
	}
}

func TestUpdateUser(t *testing.T) {
	db := openTestDB(t)
	u, _ := db.CreateUser("henry", "henry@example.com", "pw", "user")
	u.Email = "henry-new@example.com"
	u.QuotaBytes = 1024 * 1024 * 100 // 100 MB
	if err := db.UpdateUser(u); err != nil {
		t.Fatalf("UpdateUser: %v", err)
	}
	got, _ := db.GetUserByID(u.ID)
	if got.Email != "henry-new@example.com" {
		t.Errorf("Email = %q, want henry-new@example.com", got.Email)
	}
	if got.QuotaBytes != u.QuotaBytes {
		t.Errorf("QuotaBytes = %d, want %d", got.QuotaBytes, u.QuotaBytes)
	}
}

func TestDeleteUser(t *testing.T) {
	db := openTestDB(t)
	u, _ := db.CreateUser("iris", "iris@example.com", "pw", "user")
	if err := db.DeleteUser(u.ID); err != nil {
		t.Fatalf("DeleteUser: %v", err)
	}
	_, err := db.GetUserByID(u.ID)
	if !errors.Is(err, ErrUserNotFound) {
		t.Errorf("expected ErrUserNotFound after delete, got %v", err)
	}
}

func TestDeleteUser_NotFound(t *testing.T) {
	db := openTestDB(t)
	err := db.DeleteUser("nonexistent")
	if !errors.Is(err, ErrUserNotFound) {
		t.Errorf("expected ErrUserNotFound, got %v", err)
	}
}
