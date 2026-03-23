package email

import (
	"strings"
	"testing"
)

// TestNewService verifies that a Service is correctly constructed.
func TestNewService(t *testing.T) {
	svc := NewService("smtp.example.com", 587, "user@example.com", "secret", "SyncVault <noreply@example.com>", true)
	if svc == nil {
		t.Fatal("expected non-nil service")
	}
	if !svc.Enabled() {
		t.Error("expected service to be enabled")
	}
}

// TestService_Disabled verifies that all send methods are no-ops when disabled.
func TestService_Disabled(t *testing.T) {
	svc := NewService("", 587, "", "", "", false)

	if err := svc.SendWelcome("u@example.com", "user", "pass", ""); err != nil {
		t.Errorf("SendWelcome on disabled service: %v", err)
	}
	if err := svc.SendPasswordReset("u@example.com", "user", "newpass"); err != nil {
		t.Errorf("SendPasswordReset on disabled service: %v", err)
	}
	if err := svc.SendQuotaWarning("u@example.com", "user", 900, 1000, 90); err != nil {
		t.Errorf("SendQuotaWarning on disabled service: %v", err)
	}
}

// TestRenderWelcomeTemplate verifies the welcome template renders the expected content.
func TestRenderWelcomeTemplate(t *testing.T) {
	// Without PIN
	dataNoPin := struct {
		Username string
		Password string
		PIN      string
	}{Username: "alice", Password: "secret123", PIN: ""}

	body, err := renderTemplate(welcomeTmpl, dataNoPin)
	if err != nil {
		t.Fatalf("render welcome template (no PIN): %v", err)
	}
	checks := []string{"alice", "secret123", "Welcome to SyncVault", "change your password"}
	for _, want := range checks {
		if !strings.Contains(body, want) {
			t.Errorf("welcome body (no PIN) missing %q; body = %q", want, body)
		}
	}
	if strings.Contains(body, "Connection PIN") {
		t.Error("welcome body without PIN should not contain 'Connection PIN'")
	}

	// With PIN
	dataWithPin := struct {
		Username string
		Password string
		PIN      string
	}{Username: "alice", Password: "secret123", PIN: "AB3X7K"}

	bodyWithPin, err := renderTemplate(welcomeTmpl, dataWithPin)
	if err != nil {
		t.Fatalf("render welcome template (with PIN): %v", err)
	}
	pinChecks := []string{"AB3X7K", "Connection PIN", ".syncvault"}
	for _, want := range pinChecks {
		if !strings.Contains(bodyWithPin, want) {
			t.Errorf("welcome body (with PIN) missing %q; body = %q", want, bodyWithPin)
		}
	}
}

// TestRenderPasswordResetTemplate verifies the password reset template renders correctly.
func TestRenderPasswordResetTemplate(t *testing.T) {
	data := struct {
		Username string
		Password string
	}{Username: "bob", Password: "newpass456"}

	body, err := renderTemplate(passwordResetTmpl, data)
	if err != nil {
		t.Fatalf("render password reset template: %v", err)
	}

	checks := []string{"bob", "newpass456", "password has been reset", "change it"}
	for _, want := range checks {
		if !strings.Contains(body, want) {
			t.Errorf("password reset body missing %q; body = %q", want, body)
		}
	}
}

// TestRenderQuotaWarningTemplate verifies the quota warning template renders correctly.
func TestRenderQuotaWarningTemplate(t *testing.T) {
	data := struct {
		Username   string
		UsedHuman  string
		QuotaHuman string
		Percentage int
	}{
		Username:   "carol",
		UsedHuman:  formatBytes(900 * 1024 * 1024),
		QuotaHuman: formatBytes(1024 * 1024 * 1024),
		Percentage: 87,
	}

	body, err := renderTemplate(quotaWarningTmpl, data)
	if err != nil {
		t.Fatalf("render quota warning template: %v", err)
	}

	checks := []string{"carol", "87%", "quota warning", "free up space"}
	for _, want := range checks {
		if !strings.Contains(body, want) {
			t.Errorf("quota warning body missing %q; body = %q", want, body)
		}
	}
}

// TestFormatBytes verifies the byte formatting helper.
func TestFormatBytes(t *testing.T) {
	cases := []struct {
		input int64
		want  string
	}{
		{0, "0 B"},
		{512, "512 B"},
		{1024, "1.0 KB"},
		{1024 * 1024, "1.0 MB"},
		{1536 * 1024, "1.5 MB"},
		{1024 * 1024 * 1024, "1.0 GB"},
	}

	for _, tc := range cases {
		got := formatBytes(tc.input)
		if got != tc.want {
			t.Errorf("formatBytes(%d) = %q, want %q", tc.input, got, tc.want)
		}
	}
}

// TestSendWelcome_EnabledNoServer verifies that SendWelcome returns an error
// when SMTP is enabled but the server is unreachable, without panicking.
func TestSendWelcome_EnabledNoServer(t *testing.T) {
	// Use an address that is guaranteed to be unreachable.
	svc := NewService("127.0.0.1", 19999, "u", "p", "Test <t@t.com>", true)

	err := svc.SendWelcome("dest@example.com", "alice", "pass123", "AB3X7K")
	if err == nil {
		t.Error("expected error when SMTP server is unreachable, got nil")
	}
}

// TestSendPasswordReset_EnabledNoServer verifies that SendPasswordReset returns an error
// when SMTP is enabled but the server is unreachable.
func TestSendPasswordReset_EnabledNoServer(t *testing.T) {
	svc := NewService("127.0.0.1", 19999, "u", "p", "Test <t@t.com>", true)

	err := svc.SendPasswordReset("dest@example.com", "bob", "newpass456")
	if err == nil {
		t.Error("expected error when SMTP server is unreachable, got nil")
	}
}

// TestSendQuotaWarning_EnabledNoServer verifies that SendQuotaWarning returns an error
// when SMTP is enabled but the server is unreachable.
func TestSendQuotaWarning_EnabledNoServer(t *testing.T) {
	svc := NewService("127.0.0.1", 19999, "u", "p", "Test <t@t.com>", true)

	err := svc.SendQuotaWarning("dest@example.com", "carol", 900*1024*1024, 1024*1024*1024, 87)
	if err == nil {
		t.Error("expected error when SMTP server is unreachable, got nil")
	}
}
