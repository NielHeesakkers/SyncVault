package rest

import (
	"sync"
	"time"
)

// FileEvent describes a file mutation that subscribers care about.
// Kept small intentionally — clients use it as a signal to refresh their cache
// or fetch a single file, not as a full file payload.
type FileEvent struct {
	Type         string    `json:"type"` // "file_created" | "file_updated" | "file_deleted"
	FileID       string    `json:"file_id"`
	OwnerID      string    `json:"owner_id"`
	RelativePath string    `json:"relative_path,omitempty"`
	Name         string    `json:"name,omitempty"`
	IsDir        bool      `json:"is_dir,omitempty"`
	Size         int64     `json:"size,omitempty"`
	ContentHash  string    `json:"content_hash,omitempty"`
	Rank         int64     `json:"rank"` // _change_rank value at mutation time
	At           time.Time `json:"at"`
}

// Broadcaster is a per-server pub/sub for FileEvents. Subscribers receive every
// event from any user; the subscriber filters by OwnerID when emitting to its
// client (a user's session only cares about their own files).
//
// Bounded per-subscriber channel buffer prevents one slow client from blocking
// the publisher; if the channel fills, that subscriber is dropped (client will
// reconnect and get a fresh tree fetch via the existing ETag path).
type Broadcaster struct {
	mu          sync.Mutex
	subscribers map[chan FileEvent]struct{}
}

// NewBroadcaster returns a broadcaster ready for Subscribe/Publish.
func NewBroadcaster() *Broadcaster {
	return &Broadcaster{subscribers: make(map[chan FileEvent]struct{})}
}

// Subscribe registers a new subscriber. Returns the receive channel + an
// unsubscribe function. Caller MUST call unsubscribe (typically via defer) so
// disconnected clients are cleaned up.
//
// Buffer size 64 = enough for several seconds of typical activity without
// dropping the slow consumer; once full, that subscriber is removed.
func (b *Broadcaster) Subscribe() (<-chan FileEvent, func()) {
	ch := make(chan FileEvent, 64)
	b.mu.Lock()
	b.subscribers[ch] = struct{}{}
	b.mu.Unlock()
	return ch, func() {
		b.mu.Lock()
		if _, ok := b.subscribers[ch]; ok {
			delete(b.subscribers, ch)
			close(ch)
		}
		b.mu.Unlock()
	}
}

// Publish fans out the event to every subscriber. Non-blocking: if a subscriber's
// buffer is full, we drop the slow consumer so other clients keep getting events.
// The dropped client will reconnect and rebuild state via the ETag/tree fetch path.
func (b *Broadcaster) Publish(ev FileEvent) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for ch := range b.subscribers {
		select {
		case ch <- ev:
		default:
			// Slow consumer — drop it. Subscriber will see the closed channel.
			delete(b.subscribers, ch)
			close(ch)
		}
	}
}

// SubscriberCount is used by /api/health diagnostics.
func (b *Broadcaster) SubscriberCount() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return len(b.subscribers)
}
