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
func Load() *Config {
	cfg := &Config{
		DataDir:      getEnv("DATA_DIR", DefaultDataDir),
		HTTPPort:     getEnvInt("HTTP_PORT", DefaultHTTPPort),
		GRPCPort:     getEnvInt("GRPC_PORT", DefaultGRPCPort),
		JWTSecret:    getEnv("JWT_SECRET", ""),
		TLSCertFile:  getEnv("TLS_CERT_FILE", ""),
		TLSKeyFile:   getEnv("TLS_KEY_FILE", ""),
		MaxChunkSize: getEnvInt("MAX_CHUNK_SIZE", DefaultMaxChunkSize),
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
