package rest

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
)

// handleSSE establishes a Server-Sent Events connection for real-time push notifications.
// Clients receive "connected" on open and "changes" whenever files are updated.
func (s *Server) handleSSE(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())

	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "SSE not supported", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("Access-Control-Allow-Origin", "*")

	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	lastCheck := time.Now()

	// Send initial connected event
	fmt.Fprintf(w, "event: connected\ndata: {\"user\":\"%s\"}\n\n", claims.Username)
	flusher.Flush()

	for {
		select {
		case <-r.Context().Done():
			return
		case <-ticker.C:
			// Check for file changes
			changes, err := s.db.GetChangesSince(claims.UserID, lastCheck)
			if err == nil && len(changes) > 0 {
				data, _ := json.Marshal(map[string]interface{}{
					"changes": len(changes),
					"since":   lastCheck.Format(time.RFC3339Nano),
				})
				fmt.Fprintf(w, "event: changes\ndata: %s\n\n", data)
				flusher.Flush()
				lastCheck = time.Now()
			}

			// Send keepalive
			fmt.Fprintf(w, ": keepalive\n\n")
			flusher.Flush()
		}
	}
}
