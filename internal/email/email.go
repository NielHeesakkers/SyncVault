package email

import (
	"bytes"
	"crypto/tls"
	"fmt"
	"net"
	"net/smtp"
	"strconv"
	"text/template"
	"time"
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

// UpdateFromSettings updates the SMTP configuration from a settings map.
// Recognised keys: smtp.enabled, smtp.host, smtp.port, smtp.user, smtp.password, smtp.from.
// DB settings override the values set at startup (env vars).
func (s *Service) UpdateFromSettings(settings map[string]string) {
	if v, ok := settings["smtp.enabled"]; ok {
		switch v {
		case "true", "1", "yes":
			s.enabled = true
		case "false", "0", "no":
			s.enabled = false
		}
	}
	if v, ok := settings["smtp.host"]; ok && v != "" {
		s.host = v
	}
	if v, ok := settings["smtp.port"]; ok && v != "" {
		if p, err := strconv.Atoi(v); err == nil && p > 0 {
			s.port = p
		}
	}
	if v, ok := settings["smtp.user"]; ok {
		s.user = v
	}
	if v, ok := settings["smtp.password"]; ok {
		s.password = v
	}
	if v, ok := settings["smtp.from"]; ok && v != "" {
		s.from = v
	}
}

// SMTPTestResult contains the result of an SMTP connection test.
type SMTPTestResult struct {
	Host  string `json:"host"`
	Port  int    `json:"port"`
	Error string `json:"error,omitempty"`
}

// TestConnection tests the SMTP connection and authentication without sending an email.
func (s *Service) TestConnection() SMTPTestResult {
	result := SMTPTestResult{Host: s.host, Port: s.port}

	if !s.enabled {
		result.Error = "SMTP is not enabled"
		return result
	}
	if s.host == "" {
		result.Error = "SMTP host is not configured"
		return result
	}

	addr := fmt.Sprintf("%s:%d", s.host, s.port)

	var client *smtp.Client

	if s.port == 465 {
		// Port 465: implicit TLS
		tlsConn, err := tls.DialWithDialer(&net.Dialer{Timeout: 10 * time.Second}, "tcp", addr, &tls.Config{ServerName: s.host})
		if err != nil {
			result.Error = fmt.Sprintf("TLS connection to %s failed: %v", addr, err)
			return result
		}
		client, err = smtp.NewClient(tlsConn, s.host)
		if err != nil {
			tlsConn.Close()
			result.Error = fmt.Sprintf("SMTP handshake failed: %v", err)
			return result
		}
	} else {
		// Port 587: plaintext + STARTTLS
		conn, err := net.DialTimeout("tcp", addr, 10*time.Second)
		if err != nil {
			result.Error = fmt.Sprintf("Cannot connect to %s — %v", addr, err)
			return result
		}
		client, err = smtp.NewClient(conn, s.host)
		if err != nil {
			conn.Close()
			result.Error = fmt.Sprintf("SMTP handshake failed: %v", err)
			return result
		}
	}
	defer client.Close()

	// Test authentication
	smtpAuth := smtp.PlainAuth("", s.user, s.password, s.host)
	if err := client.Auth(smtpAuth); err != nil {
		result.Error = fmt.Sprintf("Authentication failed: %v", err)
		return result
	}

	client.Quit()
	return result
}

const emailWrapper = `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head><body style="margin:0;padding:0;background:#f4f5f7;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif"><table width="100%%" cellpadding="0" cellspacing="0" style="background:#f4f5f7;padding:40px 20px"><tr><td align="center"><table width="560" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:12px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,0.08)"><tr><td style="background:linear-gradient(135deg,#2563eb,#1d4ed8);padding:32px 40px;text-align:center"><img src="data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iNDAiIGhlaWdodD0iNDAiIHZpZXdCb3g9IjAgMCA0MCA0MCIgZmlsbD0ibm9uZSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj48cmVjdCB3aWR0aD0iNDAiIGhlaWdodD0iNDAiIHJ4PSI4IiBmaWxsPSJ3aGl0ZSIgZmlsbC1vcGFjaXR5PSIwLjIiLz48cGF0aCBkPSJNMTIgMjBMMjAgMjhMMjggMTIiIHN0cm9rZT0id2hpdGUiIHN0cm9rZS13aWR0aD0iMyIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIi8+PC9zdmc+" alt="" style="width:40px;height:40px;margin-bottom:12px"><h1 style="margin:0;color:#ffffff;font-size:22px;font-weight:600;letter-spacing:-0.3px">SyncVault</h1></td></tr><tr><td style="padding:36px 40px">%s</td></tr><tr><td style="padding:0 40px 32px"><hr style="border:none;border-top:1px solid #e5e7eb;margin:0 0 20px"><p style="margin:0;font-size:12px;color:#9ca3af;text-align:center">This is an automated message from SyncVault — please do not reply.</p></td></tr></table></td></tr></table></body></html>`

var testEmailTmpl = template.Must(template.New("test_email").Parse(fmt.Sprintf(emailWrapper, `
<h2 style="margin:0 0 16px;font-size:18px;font-weight:600;color:#111827">SMTP Test Successful</h2>
<p style="margin:0 0 12px;font-size:14px;line-height:1.6;color:#374151">Your SMTP settings are working correctly. SyncVault can now send email notifications.</p>
<div style="background:#f0fdf4;border:1px solid #bbf7d0;border-radius:8px;padding:16px;margin:16px 0">
<p style="margin:0;font-size:14px;color:#166534">&#10003; Connection verified</p>
</div>
`)))

// SendTestEmail sends a test email to the given address to verify SMTP settings.
func (s *Service) SendTestEmail(toEmail string) error {
	body, err := renderTemplate(testEmailTmpl, nil)
	if err != nil {
		return fmt.Errorf("render test email template: %w", err)
	}
	return s.send(toEmail, "SyncVault: SMTP test email", body)
}

var welcomeTmpl = template.Must(template.New("welcome").Parse(fmt.Sprintf(emailWrapper, `
<h2 style="margin:0 0 16px;font-size:18px;font-weight:600;color:#111827">Welcome to SyncVault!</h2>
<p style="margin:0 0 20px;font-size:14px;line-height:1.6;color:#374151">Your account has been created. Here are your login credentials:</p>
<div style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:8px;padding:20px;margin:16px 0">
<table cellpadding="0" cellspacing="0" style="width:100%%">
<tr><td style="padding:4px 0;font-size:13px;color:#6b7280;width:100px">Username</td><td style="padding:4px 0;font-size:14px;font-weight:600;color:#111827;font-family:monospace">{{.Username}}</td></tr>
<tr><td style="padding:4px 0;font-size:13px;color:#6b7280">Password</td><td style="padding:4px 0;font-size:14px;font-weight:600;color:#111827;font-family:monospace">{{.Password}}</td></tr>
</table>
</div>
{{if .PIN}}
<div style="background:#eff6ff;border:1px solid #bfdbfe;border-radius:8px;padding:20px;margin:16px 0">
<p style="margin:0 0 8px;font-size:13px;font-weight:600;color:#1e40af">Connection PIN</p>
<p style="margin:0;font-size:28px;font-weight:700;color:#1d4ed8;letter-spacing:4px;font-family:monospace;text-align:center">{{.PIN}}</p>
<p style="margin:12px 0 0;font-size:12px;color:#3b82f6">Download your .syncvault token file from the admin panel and open it with the SyncVault app. Enter this PIN when prompted.</p>
</div>
{{end}}
<p style="margin:16px 0 0;font-size:13px;color:#6b7280">Please change your password after your first login.</p>
`)))

var passwordResetTmpl = template.Must(template.New("password_reset").Parse(fmt.Sprintf(emailWrapper, `
<h2 style="margin:0 0 16px;font-size:18px;font-weight:600;color:#111827">Password Reset</h2>
<p style="margin:0 0 20px;font-size:14px;line-height:1.6;color:#374151">Hello {{.Username}}, your SyncVault password has been reset by an administrator.</p>
<div style="background:#fef3c7;border:1px solid #fcd34d;border-radius:8px;padding:20px;margin:16px 0">
<table cellpadding="0" cellspacing="0" style="width:100%%">
<tr><td style="padding:4px 0;font-size:13px;color:#92400e">New password</td><td style="padding:4px 0;font-size:16px;font-weight:700;color:#92400e;font-family:monospace">{{.Password}}</td></tr>
</table>
</div>
<p style="margin:16px 0 0;font-size:13px;color:#6b7280">If this wasn't you, log in and change it immediately.</p>
`)))

var passwordResetLinkTmpl = template.Must(template.New("password_reset_link").Parse(fmt.Sprintf(emailWrapper, `
<h2 style="margin:0 0 16px;font-size:18px;font-weight:600;color:#111827">Reset Your Password</h2>
<p style="margin:0 0 20px;font-size:14px;line-height:1.6;color:#374151">You requested a password reset for your SyncVault account. Click the button below to set a new password.</p>
<div style="text-align:center;margin:24px 0">
<a href="{{.ResetLink}}" style="display:inline-block;background:#2563eb;color:#ffffff;text-decoration:none;padding:12px 32px;border-radius:8px;font-size:14px;font-weight:600">Reset Password</a>
</div>
<p style="margin:16px 0 0;font-size:12px;color:#9ca3af">This link is valid for 1 hour. If you didn't request this, you can safely ignore this email.</p>
`)))

// SendPasswordResetLink sends a self-service password reset email containing the reset link.
func (s *Service) SendPasswordResetLink(toEmail, resetLink string) error {
	if !s.enabled {
		return nil
	}
	data := struct {
		ResetLink string
	}{ResetLink: resetLink}

	body, err := renderTemplate(passwordResetLinkTmpl, data)
	if err != nil {
		return fmt.Errorf("render password reset link template: %w", err)
	}

	return s.send(toEmail, "SyncVault \u2014 Password Reset", body)
}

var quotaWarningTmpl = template.Must(template.New("quota_warning").Parse(fmt.Sprintf(emailWrapper, `
<h2 style="margin:0 0 16px;font-size:18px;font-weight:600;color:#111827">Storage Quota Warning</h2>
<p style="margin:0 0 20px;font-size:14px;line-height:1.6;color:#374151">Hello {{.Username}}, you are running low on storage space.</p>
<div style="background:#fef2f2;border:1px solid #fecaca;border-radius:8px;padding:20px;margin:16px 0">
<div style="display:flex;justify-content:space-between;margin-bottom:12px">
<span style="font-size:14px;font-weight:600;color:#991b1b">{{.Percentage}}%% used</span>
<span style="font-size:13px;color:#6b7280">{{.UsedHuman}} / {{.QuotaHuman}}</span>
</div>
<div style="background:#fee2e2;border-radius:4px;height:8px;overflow:hidden">
<div style="background:#ef4444;height:100%%;width:{{.Percentage}}%%;border-radius:4px"></div>
</div>
</div>
<p style="margin:16px 0 0;font-size:13px;color:#6b7280">Please free up space or contact your administrator.</p>
`)))

// SendWelcome sends a welcome email with login credentials to a newly created user.
// The pin parameter is optional; pass an empty string if no token was generated.
func (s *Service) SendWelcome(toEmail, username, password, pin string) error {
	if !s.enabled {
		return nil
	}
	data := struct {
		Username string
		Password string
		PIN      string
	}{Username: username, Password: password, PIN: pin}

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

// send composes and sends a plain-text email via SMTP with a 10-second timeout.
func (s *Service) send(to, subject, body string) error {
	addr := fmt.Sprintf("%s:%d", s.host, s.port)

	msg := []byte(
		"From: SyncVault <" + s.from + ">\r\n" +
			"To: " + to + "\r\n" +
			"Subject: " + subject + "\r\n" +
			"MIME-Version: 1.0\r\n" +
			"Content-Type: text/html; charset=UTF-8\r\n" +
			"\r\n" +
			body,
	)

	// Connect with TLS for port 465 (implicit TLS), STARTTLS for others
	var client *smtp.Client
	if s.port == 465 {
		tlsConn, err := tls.DialWithDialer(&net.Dialer{Timeout: 10 * time.Second}, "tcp", addr, &tls.Config{ServerName: s.host})
		if err != nil {
			return fmt.Errorf("SMTP TLS connection failed: %w", err)
		}
		client, err = smtp.NewClient(tlsConn, s.host)
		if err != nil {
			tlsConn.Close()
			return fmt.Errorf("SMTP client error: %w", err)
		}
	} else {
		conn, err := net.DialTimeout("tcp", addr, 10*time.Second)
		if err != nil {
			return fmt.Errorf("SMTP connection failed: %w", err)
		}
		client, err = smtp.NewClient(conn, s.host)
		if err != nil {
			conn.Close()
			return fmt.Errorf("SMTP client error: %w", err)
		}
		// STARTTLS for port 587
		if err := client.StartTLS(&tls.Config{ServerName: s.host}); err != nil {
			client.Close()
			return fmt.Errorf("SMTP STARTTLS failed: %w", err)
		}
	}
	defer client.Close()

	// Auth
	auth := smtp.PlainAuth("", s.user, s.password, s.host)
	if err := client.Auth(auth); err != nil {
		return fmt.Errorf("SMTP auth failed: %w", err)
	}

	// Set sender and recipient
	if err := client.Mail(s.user); err != nil {
		return fmt.Errorf("SMTP MAIL FROM failed: %w", err)
	}
	if err := client.Rcpt(to); err != nil {
		return fmt.Errorf("SMTP RCPT TO failed: %w", err)
	}

	// Send body
	w, err := client.Data()
	if err != nil {
		return fmt.Errorf("SMTP DATA failed: %w", err)
	}
	if _, err := w.Write(msg); err != nil {
		return fmt.Errorf("SMTP write failed: %w", err)
	}
	if err := w.Close(); err != nil {
		return fmt.Errorf("SMTP send failed: %w", err)
	}

	return client.Quit()
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
