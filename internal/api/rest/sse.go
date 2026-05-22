package rest

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
)

// handleSSE establishes a Server-Sent Events connection for real-time push.
//
// On open the client receives a "connected" event with their identity. From
// then on, every file mutation (by this user — others are filtered out) is
// pushed as a "file" event immediately, via the Broadcaster pub/sub.
//
// A 30-second keepalive comment keeps middleboxes from closing the connection.
// There is no polling fallback any more — clients that need a full sync should
// hit /api/files/tree (which returns 304 via ETag when nothing changed).
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
	w.Header().Set("X-Accel-Buffering", "no") // disable nginx proxy buffering
	w.Header().Set("Access-Control-Allow-Origin", "*")

	events, unsubscribe := s.broadcaster.Subscribe()
	defer unsubscribe()

	fmt.Fprintf(w, "event: connected\ndata: {\"user\":\"%s\"}\n\n", claims.Username)
	flusher.Flush()

	keepalive := time.NewTicker(30 * time.Second)
	defer keepalive.Stop()

	for {
		select {
		case <-r.Context().Done():
			return

		case ev, ok := <-events:
			if !ok {
				// Broadcaster dropped us (slow consumer). Client will reconnect.
				return
			}
			// Filter: only push events for files owned by this user.
			// Admins also see everything (could be made opt-in later).
			if ev.OwnerID != claims.UserID && claims.Role != "admin" {
				continue
			}
			data, err := json.Marshal(ev)
			if err != nil {
				continue
			}
			fmt.Fprintf(w, "event: file\ndata: %s\n\n", data)
			flusher.Flush()

		case <-keepalive.C:
			fmt.Fprint(w, ": keepalive\n\n")
			flusher.Flush()
		}
	}
}
