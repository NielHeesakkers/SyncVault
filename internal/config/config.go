package config

import (
	"os"
	"strconv"
)

const (
	DefaultDataDir      = "/data"
	DefaultHTTPPort     = 8080
	DefaultGRPCPort     = 6690
	DefaultMaxChunkSize = 4 * 1024 * 1024 // 4MB
)

// Config holds all application configuration values.
type Config struct {
	DataDir      string
	HTTPPort     int
	GRPCPort     int
	JWTSecret    string
	TLSCertFile  string
	TLSKeyFile   string
	MaxChunkSize int

	// SMTP settings for email notifications.
	SMTPHost     string `json:"smtp_host"`
	SMTPPort     int    `json:"smtp_port"`
	SMTPUser     string `json:"smtp_user"`
	SMTPPassword string `json:"smtp_password"`
	SMTPFrom     string `json:"smtp_from"`
	SMTPEnabled  bool   `json:"smtp_enabled"`
}

// Load reads configuration from environment variables, falling back to defaults.
// Each setting is read from the SYNCVAULT_-prefixed name first, then the unprefixed name.
func Load() *Config {
	cfg := &Config{
		DataDir:      getEnvMulti("SYNCVAULT_DATA_DIR", "DATA_DIR", DefaultDataDir),
		HTTPPort:     getEnvIntMulti("SYNCVAULT_HTTP_PORT", "HTTP_PORT", DefaultHTTPPort),
		GRPCPort:     getEnvIntMulti("SYNCVAULT_GRPC_PORT", "GRPC_PORT", DefaultGRPCPort),
		JWTSecret:    getEnvMulti("SYNCVAULT_JWT_SECRET", "JWT_SECRET", ""),
		TLSCertFile:  getEnvMulti("SYNCVAULT_TLS_CERT_FILE", "TLS_CERT_FILE", ""),
		TLSKeyFile:   getEnvMulti("SYNCVAULT_TLS_KEY_FILE", "TLS_KEY_FILE", ""),
		MaxChunkSize: getEnvIntMulti("SYNCVAULT_MAX_CHUNK_SIZE", "MAX_CHUNK_SIZE", DefaultMaxChunkSize),

		SMTPHost:     getEnvMulti("SYNCVAULT_SMTP_HOST", "SMTP_HOST", ""),
		SMTPPort:     getEnvIntMulti("SYNCVAULT_SMTP_PORT", "SMTP_PORT", 587),
		SMTPUser:     getEnvMulti("SYNCVAULT_SMTP_USER", "SMTP_USER", ""),
		SMTPPassword: getEnvMulti("SYNCVAULT_SMTP_PASSWORD", "SMTP_PASSWORD", ""),
		SMTPFrom:     getEnvMulti("SYNCVAULT_SMTP_FROM", "SMTP_FROM", "SyncVault <noreply@example.com>"),
		SMTPEnabled:  getEnvBoolMulti("SYNCVAULT_SMTP_ENABLED", "SMTP_ENABLED", false),
	}
	return cfg
}

func getEnv(key, defaultVal string) string {
	if val, ok := os.LookupEnv(key); ok {
		return val
	}
	return defaultVal
}

func getEnvInt(key string, defaultVal int) int {
	if val, ok := os.LookupEnv(key); ok {
		if i, err := strconv.Atoi(val); err == nil {
			return i
		}
	}
	return defaultVal
}

// getEnvMulti checks primary then fallback key, returning defaultVal if neither is set.
func getEnvMulti(primary, fallback, defaultVal string) string {
	if val, ok := os.LookupEnv(primary); ok {
		return val
	}
	return getEnv(fallback, defaultVal)
}

// getEnvIntMulti checks primary then fallback key, returning defaultVal if neither is set.
func getEnvIntMulti(primary, fallback string, defaultVal int) int {
	if val, ok := os.LookupEnv(primary); ok {
		if i, err := strconv.Atoi(val); err == nil {
			return i
		}
	}
	return getEnvInt(fallback, defaultVal)
}

func getEnvBool(key string, defaultVal bool) bool {
	if val, ok := os.LookupEnv(key); ok {
		switch val {
		case "true", "1", "yes":
			return true
		case "false", "0", "no":
			return false
		}
	}
	return defaultVal
}

// getEnvBoolMulti checks primary then fallback key, returning defaultVal if neither is set.
func getEnvBoolMulti(primary, fallback string, defaultVal bool) bool {
	if val, ok := os.LookupEnv(primary); ok {
		switch val {
		case "true", "1", "yes":
			return true
		case "false", "0", "no":
			return false
		}
	}
	return getEnvBool(fallback, defaultVal)
}
