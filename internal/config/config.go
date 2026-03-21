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
