package email

import (
	"bytes"
	"fmt"
	"net/smtp"
	"text/template"
)

// Service sends transactional emails via SMTP.
type Service struct {
	host     string
	port     int
	user     string
	password string
	from     string
	enabled  bool
}

// NewService creates a new email Service.
func NewService(host string, port int, user, password, from string, enabled bool) *Service {
	return &Service{
		host:     host,
		port:     port,
		user:     user,
		password: password,
		from:     from,
		enabled:  enabled,
	}
}

// Enabled reports whether the email service is configured and enabled.
func (s *Service) Enabled() bool {
	return s.enabled
}

var welcomeTmpl = template.Must(template.New("welcome").Parse(`Welcome to SyncVault!

Your account has been created.

Username: {{.Username}}
Password: {{.Password}}

Please change your password after your first login.

This is an automated message — please do not reply.
`))

var passwordResetTmpl = template.Must(template.New("password_reset").Parse(`Hello {{.Username}},

Your SyncVault password has been reset.

New password: {{.Password}}

Please change it after logging in.

This is an automated message — please do not reply.
`))

var quotaWarningTmpl = template.Must(template.New("quota_warning").Parse(`Hello {{.Username}},

Storage quota warning: You are using {{.Percentage}}% of your quota ({{.UsedHuman}} of {{.QuotaHuman}}).

Please free up space or contact your administrator.

This is an automated message — please do not reply.
`))

// SendWelcome sends a welcome email with login credentials to a newly created user.
func (s *Service) SendWelcome(toEmail, username, password string) error {
	if !s.enabled {
		return nil
	}
	data := struct {
		Username string
		Password string
	}{Username: username, Password: password}

	body, err := renderTemplate(welcomeTmpl, data)
	if err != nil {
		return fmt.Errorf("render welcome template: %w", err)
	}

	subject := "Welcome to SyncVault!"
	return s.send(toEmail, subject, body)
}

// SendPasswordReset sends an email notifying the user that their password was reset.
func (s *Service) SendPasswordReset(toEmail, username, newPassword string) error {
	if !s.enabled {
		return nil
	}
	data := struct {
		Username string
		Password string
	}{Username: username, Password: newPassword}

	body, err := renderTemplate(passwordResetTmpl, data)
	if err != nil {
		return fmt.Errorf("render password reset template: %w", err)
	}

	subject := "SyncVault: Your password has been reset"
	return s.send(toEmail, subject, body)
}

// SendQuotaWarning sends a quota warning email when a user exceeds a usage threshold.
func (s *Service) SendQuotaWarning(toEmail, username string, usedBytes, quotaBytes int64, percentage int) error {
	if !s.enabled {
		return nil
	}
	data := struct {
		Username   string
		UsedHuman  string
		QuotaHuman string
		Percentage int
	}{
		Username:   username,
		UsedHuman:  formatBytes(usedBytes),
		QuotaHuman: formatBytes(quotaBytes),
		Percentage: percentage,
	}

	body, err := renderTemplate(quotaWarningTmpl, data)
	if err != nil {
		return fmt.Errorf("render quota warning template: %w", err)
	}

	subject := fmt.Sprintf("SyncVault: Storage quota warning (%d%% used)", percentage)
	return s.send(toEmail, subject, body)
}

// send composes and sends a plain-text email via SMTP.
func (s *Service) send(to, subject, body string) error {
	addr := fmt.Sprintf("%s:%d", s.host, s.port)
	auth := smtp.PlainAuth("", s.user, s.password, s.host)

	msg := []byte(
		"From: " + s.from + "\r\n" +
			"To: " + to + "\r\n" +
			"Subject: " + subject + "\r\n" +
			"Content-Type: text/plain; charset=UTF-8\r\n" +
			"\r\n" +
			body,
	)

	return smtp.SendMail(addr, auth, s.user, []string{to}, msg)
}

// renderTemplate executes t with data and returns the result as a string.
func renderTemplate(t *template.Template, data interface{}) (string, error) {
	var buf bytes.Buffer
	if err := t.Execute(&buf, data); err != nil {
		return "", err
	}
	return buf.String(), nil
}

// formatBytes returns a human-readable representation of a byte count.
func formatBytes(b int64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := int64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(b)/float64(div), "KMGTPE"[exp])
}
