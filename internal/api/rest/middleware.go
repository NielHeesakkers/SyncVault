package rest

import (
	"log"
	"net/http"
	"os"
	"time"
)

// CORSMiddleware adds CORS headers to every response and handles preflight OPTIONS requests.
// It reflects the request's Origin header only when it matches the server's own host,
// preventing cross-site request forgery from arbitrary domains.
func CORSMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if origin != "" {
			// Allow same-host origins (covers http/https and any port).
			allowed := false
			if r.Host != "" {
				for _, scheme := range []string{"https://", "http://"} {
					if origin == scheme+r.Host {
						allowed = true
						break
					}
				}
			}
			// Also allow requests from the configured base_url (e.g. reverse proxy domain).
			if !allowed && os.Getenv("SYNCVAULT_CORS_ORIGIN") != "" {
				allowed = origin == os.Getenv("SYNCVAULT_CORS_ORIGIN")
			}
			if allowed {
				w.Header().Set("Access-Control-Allow-Origin", origin)
				w.Header().Set("Vary", "Origin")
			}
		}
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Accept, Authorization, Content-Type, X-Requested-With")

		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}

		next.ServeHTTP(w, r)
	})
}

// responseWriter wraps http.ResponseWriter to capture the status code for logging.
type responseWriter struct {
	http.ResponseWriter
	status int
}

func (rw *responseWriter) WriteHeader(status int) {
	rw.status = status
	rw.ResponseWriter.WriteHeader(status)
}

// SecurityHeadersMiddleware adds common security headers to every response.
func SecurityHeadersMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "strict-origin-when-cross-origin")
		next.ServeHTTP(w, r)
	})
}

// LoggingMiddleware logs the HTTP method, path, response status, and duration.
func LoggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rw := &responseWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rw, r)
		log.Printf("%s %s %d %s", r.Method, r.URL.Path, rw.status, time.Since(start))
	})
}
