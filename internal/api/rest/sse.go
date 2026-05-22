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
// On open the client receives a "connected" event with their identity. If a
// device_id query param is provided AND we have a stored last_seen_rank for it,
// we first REPLAY any file events the device missed while offline (one
// "file" event per row), then proceed with the live broadcast.
//
// Live phase: every mutation by this user (others are filtered out) is pushed
// as a "file" event via the Broadcaster pub/sub. On every emit we also bump
// the device's cursor so a hard reconnect picks up where we left off.
//
// A 30-second keepalive comment keeps middleboxes from closing the connection.
// Clients that need a full snapshot should still hit /api/files/tree (which
// returns 304 via ETag when nothing changed).
func (s *Server) handleSSE(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	deviceID := r.URL.Query().Get("device_id")

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

	// Subscribe BEFORE replay so we don't miss events that fire during the
	// catch-up window. Buffer absorbs them; the replay loop runs first.
	events, unsubscribe := s.broadcaster.Subscribe()
	defer unsubscribe()

	fmt.Fprintf(w, "event: connected\ndata: {\"user\":\"%s\"}\n\n", claims.Username)
	flusher.Flush()

	// Phase C: replay missed events for this device.
	if deviceID != "" {
		if cursor, err := s.db.GetDeviceLastSeenRank(deviceID); err == nil && cursor > 0 {
			if missed, mErr := s.db.ListFilesChangedSinceRank(cursor, claims.UserID); mErr == nil {
				for _, f := range missed {
					evType := "file_updated"
					if f.Deleted {
						evType = "file_deleted"
					}
					ev := FileEvent{
						Type:        evType,
						FileID:      f.ID,
						OwnerID:     f.OwnerID,
						Name:        f.Name,
						IsDir:       f.IsDir,
						Size:        f.Size,
						ContentHash: f.ContentHash,
						Rank:        f.ChangeRank,
						At:          time.Now(),
					}
					data, _ := json.Marshal(ev)
					fmt.Fprintf(w, "event: file\ndata: %s\n\n", data)
				}
				flusher.Flush()
				if len(missed) > 0 {
					// Catch up cursor to the most recent rank we just emitted.
					_ = s.db.UpdateDeviceLastSeenRank(deviceID, claims.UserID, missed[len(missed)-1].ChangeRank)
				}
			}
		}
	}

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
			if deviceID != "" {
				_ = s.db.UpdateDeviceLastSeenRank(deviceID, claims.UserID, ev.Rank)
			}

		case <-keepalive.C:
			fmt.Fprint(w, ": keepalive\n\n")
			flusher.Flush()
		}
	}
}

