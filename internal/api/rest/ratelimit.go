package rest

import (
	"net"
	"net/http"
	"sync"
	"time"
)

// rateLimiter tracks request counts per IP within a sliding window.
type rateLimiter struct {
	mu       sync.Mutex
	requests map[string][]time.Time
	limit    int           // max requests per window
	window   time.Duration // sliding window duration
}

func newRateLimiter(limit int, window time.Duration) *rateLimiter {
	rl := &rateLimiter{
		requests: make(map[string][]time.Time),
		limit:    limit,
		window:   window,
	}
	// Periodically clean up expired entries to prevent memory leaks.
	go func() {
		for {
			time.Sleep(5 * time.Minute)
			rl.cleanup()
		}
	}()
	return rl
}

func (rl *rateLimiter) allow(ip string) bool {
	rl.mu.Lock()
	defer rl.mu.Unlock()

	now := time.Now()
	cutoff := now.Add(-rl.window)

	// Remove expired entries for this IP.
	entries := rl.requests[ip]
	start := 0
	for start < len(entries) && entries[start].Before(cutoff) {
		start++
	}
	entries = entries[start:]

	if len(entries) >= rl.limit {
		rl.requests[ip] = entries
		return false
	}

	rl.requests[ip] = append(entries, now)
	return true
}

func (rl *rateLimiter) cleanup() {
	rl.mu.Lock()
	defer rl.mu.Unlock()

	cutoff := time.Now().Add(-rl.window)
	for ip, entries := range rl.requests {
		start := 0
		for start < len(entries) && entries[start].Before(cutoff) {
			start++
		}
		if start >= len(entries) {
			delete(rl.requests, ip)
		} else {
			rl.requests[ip] = entries[start:]
		}
	}
}

// clientIP extracts the client IP from the request, preferring X-Forwarded-For
// (first entry) for reverse proxy setups, falling back to RemoteAddr.
func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		// Take the first (client) IP from the chain.
		for i := 0; i < len(xff); i++ {
			if xff[i] == ',' {
				return xff[:i]
			}
		}
		return xff
	}
	ip, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return ip
}

// RateLimitMiddleware returns middleware that limits requests per IP.
func RateLimitMiddleware(limit int, window time.Duration) func(http.Handler) http.Handler {
	rl := newRateLimiter(limit, window)
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ip := clientIP(r)
			if !rl.allow(ip) {
				w.Header().Set("Retry-After", "60")
				writeJSON(w, http.StatusTooManyRequests, map[string]string{
					"error": "too many requests, please try again later",
				})
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}
