# SyncVault Server Core — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the SyncVault server core — a single Go binary that provides content-addressable file storage, user authentication, file versioning with delta patches, REST API, gRPC sync API, and Docker deployment.

**Architecture:** Modular monolith in Go. All packages live in `internal/` with clean boundaries. SQLite stores all metadata. Files are stored as content-addressed chunks on disk. gRPC handles sync clients, REST handles the web UI. Single Docker container exposes ports 8080 (REST) and 6690 (gRPC).

**Tech Stack:** Go 1.22+, SQLite (modernc.org/sqlite), chi router, gRPC + protobuf, bcrypt, JWT, fsnotify, Docker

**Spec:** `docs/superpowers/specs/2026-03-21-syncvault-server-design.md`

---

## File Structure

```
syncvault/
├── cmd/
│   └── server/
│       └── main.go                    # Entry point, wires all packages together
├── internal/
│   ├── config/
│   │   └── config.go                  # Loads config from env vars and /data/config.json
│   ├── metadata/
│   │   ├── db.go                      # SQLite connection pool, migrations runner
│   │   ├── schema.sql                 # Full database schema
│   │   ├── files.go                   # File/folder CRUD operations
│   │   ├── users.go                   # User account CRUD
│   │   ├── versions.go                # Version history records
│   │   ├── devices.go                 # Connected device tracking
│   │   ├── activity.go                # Activity log writes and queries
│   │   ├── shares.go                  # Share link CRUD
│   │   ├── teams.go                   # Team folder and permission CRUD
│   │   └── quotas.go                  # Storage quota tracking
│   ├── storage/
│   │   ├── store.go                   # Content-addressable store: put/get/delete chunks
│   │   └── chunker.go                 # Split files into fixed-size chunks, compute hashes
│   ├── auth/
│   │   ├── auth.go                    # JWT generation, validation, refresh
│   │   ├── passwords.go               # bcrypt hash + verify
│   │   └── middleware.go              # HTTP and gRPC auth middleware
│   ├── versioning/
│   │   ├── versioning.go              # Create version, get version, restore version
│   │   ├── delta.go                   # Binary diff (create patch) and apply patch
│   │   ├── rotation.go               # FIFO and Intelliversioning rotation algorithms
│   │   └── retention.go              # Age-based cleanup (daily/weekly/monthly/yearly tiers)
│   ├── sync/
│   │   ├── engine.go                  # Sync coordination: compare trees, resolve actions
│   │   ├── conflict.go               # Conflict detection and resolution
│   │   └── selective.go              # Selective sync rule matching
│   ├── watcher/
│   │   └── watcher.go                # fsnotify wrapper, broadcasts changes to subscribers
│   ├── sharing/
│   │   └── sharing.go                # Generate/validate share links, enforce limits
│   └── api/
│       ├── rest/
│       │   ├── server.go              # chi router setup, middleware chain
│       │   ├── files.go               # GET/POST/PUT/DELETE /api/files/*
│       │   ├── users.go               # /api/users/*, /api/auth/*
│       │   ├── versions.go            # /api/files/{id}/versions/*
│       │   ├── shares.go              # /api/shares/*
│       │   ├── teams.go               # /api/teams/*
│       │   ├── admin.go               # /api/admin/* (storage insights, activity log)
│       │   └── middleware.go          # CORS, request logging, rate limiting
│       └── grpc/
│           ├── server.go              # gRPC server setup
│           ├── sync_service.go        # SyncService implementation
│           └── backup_service.go      # BackupService implementation
├── proto/
│   └── syncvault/
│       ├── sync.proto                 # Sync service protobuf definitions
│       └── backup.proto               # Backup service protobuf definitions
├── tests/
│   └── integration/
│       └── server_test.go             # Full server integration tests
├── Dockerfile
├── docker-compose.yml
├── Makefile
├── go.mod
└── go.sum
```

---

## Chunk 1: Project Setup + Storage Engine + Metadata

### Task 1: Initialize Go Project

**Files:**
- Create: `go.mod`
- Create: `Makefile`
- Create: `cmd/server/main.go`
- Create: `internal/config/config.go`

- [ ] **Step 1: Initialize Go module**

```bash
cd "/Users/niel/Development/Sync & Backup"
go mod init github.com/NielHeesakkers/SyncVault
```

- [ ] **Step 2: Create directory structure**

```bash
mkdir -p cmd/server internal/{config,metadata,storage,auth,versioning,sync,watcher,sharing,api/{rest,grpc}} proto/syncvault tests/integration
```

- [ ] **Step 3: Write config package**

Create `internal/config/config.go`:

```go
package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

type Config struct {
	DataDir      string `json:"data_dir"`
	HTTPPort     int    `json:"http_port"`
	GRPCPort     int    `json:"grpc_port"`
	JWTSecret    string `json:"jwt_secret"`
	TLSCertFile  string `json:"tls_cert_file"`
	TLSKeyFile   string `json:"tls_key_file"`
	MaxChunkSize int    `json:"max_chunk_size"`
}

func Default() *Config {
	return &Config{
		DataDir:      envOr("SYNCVAULT_DATA_DIR", "/data"),
		HTTPPort:     envIntOr("SYNCVAULT_HTTP_PORT", 8080),
		GRPCPort:     envIntOr("SYNCVAULT_GRPC_PORT", 6690),
		JWTSecret:    envOr("SYNCVAULT_JWT_SECRET", ""),
		TLSCertFile:  envOr("SYNCVAULT_TLS_CERT", ""),
		TLSKeyFile:   envOr("SYNCVAULT_TLS_KEY", ""),
		MaxChunkSize: envIntOr("SYNCVAULT_CHUNK_SIZE", 4*1024*1024), // 4MB
	}
}

func Load(path string) (*Config, error) {
	cfg := Default()
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return cfg, nil
		}
		return nil, err
	}
	defer f.Close()
	if err := json.NewDecoder(f).Decode(cfg); err != nil {
		return nil, err
	}
	return cfg, nil
}

func (c *Config) StoragePath() string {
	return filepath.Join(c.DataDir, "chunks")
}

func (c *Config) DBPath() string {
	return filepath.Join(c.DataDir, "vault.db")
}

func (c *Config) ConfigPath() string {
	return filepath.Join(c.DataDir, "config.json")
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envIntOr(key string, fallback int) int {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	var i int
	if _, err := fmt.Sscanf(v, "%d", &i); err != nil {
		return fallback
	}
	return i
}
```

- [ ] **Step 4: Write minimal main.go**

Create `cmd/server/main.go`:

```go
package main

import (
	"fmt"
	"log"
	"os"

	"github.com/NielHeesakkers/SyncVault/internal/config"
)

func main() {
	cfg, err := config.Load(config.Default().ConfigPath())
	if err != nil {
		log.Fatalf("failed to load config: %v", err)
	}

	if err := os.MkdirAll(cfg.DataDir, 0755); err != nil {
		log.Fatalf("failed to create data dir: %v", err)
	}

	fmt.Printf("SyncVault server starting\n")
	fmt.Printf("  Data dir:  %s\n", cfg.DataDir)
	fmt.Printf("  HTTP port: %d\n", cfg.HTTPPort)
	fmt.Printf("  gRPC port: %d\n", cfg.GRPCPort)
}
```

- [ ] **Step 5: Write Makefile**

Create `Makefile`:

```makefile
.PHONY: build run test clean

build:
	go build -o bin/syncvault ./cmd/server

run: build
	SYNCVAULT_DATA_DIR=./tmp/data ./bin/syncvault

test:
	go test ./... -v -count=1

clean:
	rm -rf bin/ tmp/
```

- [ ] **Step 6: Verify it compiles and runs**

```bash
make run
```

Expected: prints "SyncVault server starting" with config values.

- [ ] **Step 7: Commit**

```bash
git add go.mod Makefile cmd/ internal/config/
git commit -m "feat: initialize Go project with config package"
```

---

### Task 2: Content-Addressable Storage Engine

**Files:**
- Create: `internal/storage/store.go`
- Create: `internal/storage/chunker.go`
- Create: `internal/storage/store_test.go`
- Create: `internal/storage/chunker_test.go`

- [ ] **Step 1: Write chunker test**

Create `internal/storage/chunker_test.go`:

```go
package storage

import (
	"bytes"
	"io"
	"strings"
	"testing"
)

func TestChunker_FixedSize(t *testing.T) {
	// 10 bytes of data, 4-byte chunk size → 3 chunks (4+4+2)
	data := "abcdefghij"
	c := NewChunker(4)
	chunks, err := c.Chunk(strings.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	if len(chunks) != 3 {
		t.Fatalf("expected 3 chunks, got %d", len(chunks))
	}
	if string(chunks[0].Data) != "abcd" {
		t.Fatalf("chunk 0: expected 'abcd', got '%s'", chunks[0].Data)
	}
	if string(chunks[1].Data) != "efgh" {
		t.Fatalf("chunk 1: expected 'efgh', got '%s'", chunks[1].Data)
	}
	if string(chunks[2].Data) != "ij" {
		t.Fatalf("chunk 2: expected 'ij', got '%s'", chunks[2].Data)
	}
}

func TestChunker_HashDeterministic(t *testing.T) {
	c := NewChunker(1024)
	data := "hello world"
	chunks1, _ := c.Chunk(strings.NewReader(data))
	chunks2, _ := c.Chunk(strings.NewReader(data))
	if chunks1[0].Hash != chunks2[0].Hash {
		t.Fatal("same data should produce same hash")
	}
}

func TestChunker_DifferentDataDifferentHash(t *testing.T) {
	c := NewChunker(1024)
	chunks1, _ := c.Chunk(strings.NewReader("hello"))
	chunks2, _ := c.Chunk(strings.NewReader("world"))
	if chunks1[0].Hash == chunks2[0].Hash {
		t.Fatal("different data should produce different hash")
	}
}

func TestChunker_Reassemble(t *testing.T) {
	data := make([]byte, 10000)
	for i := range data {
		data[i] = byte(i % 256)
	}
	c := NewChunker(1024)
	chunks, err := c.Chunk(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	var reassembled bytes.Buffer
	for _, chunk := range chunks {
		reassembled.Write(chunk.Data)
	}
	if !bytes.Equal(data, reassembled.Bytes()) {
		t.Fatal("reassembled data does not match original")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/storage/ -v -run TestChunker
```

Expected: FAIL — `NewChunker` not defined.

- [ ] **Step 3: Implement chunker**

Create `internal/storage/chunker.go`:

```go
package storage

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
)

type Chunk struct {
	Hash  string
	Data  []byte
	Size  int64
	Index int
}

type Chunker struct {
	chunkSize int
}

func NewChunker(chunkSize int) *Chunker {
	return &Chunker{chunkSize: chunkSize}
}

func (c *Chunker) Chunk(r io.Reader) ([]Chunk, error) {
	var chunks []Chunk
	buf := make([]byte, c.chunkSize)
	idx := 0

	for {
		n, err := io.ReadFull(r, buf)
		if n > 0 {
			data := make([]byte, n)
			copy(data, buf[:n])
			hash := sha256.Sum256(data)
			chunks = append(chunks, Chunk{
				Hash:  hex.EncodeToString(hash[:]),
				Data:  data,
				Size:  int64(n),
				Index: idx,
			})
			idx++
		}
		if err == io.EOF || err == io.ErrUnexpectedEOF {
			break
		}
		if err != nil {
			return nil, err
		}
	}
	return chunks, nil
}

func HashBytes(data []byte) string {
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:])
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
go test ./internal/storage/ -v -run TestChunker
```

Expected: all 4 tests PASS.

- [ ] **Step 5: Write store test**

Create `internal/storage/store_test.go`:

```go
package storage

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func tempStore(t *testing.T) *Store {
	t.Helper()
	dir := t.TempDir()
	s, err := NewStore(dir, 1024)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestStore_PutAndGet(t *testing.T) {
	s := tempStore(t)
	data := []byte("hello world, this is a test file")

	fileHash, size, err := s.Put(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	if size != int64(len(data)) {
		t.Fatalf("expected size %d, got %d", len(data), size)
	}

	var buf bytes.Buffer
	err = s.Get(fileHash, &buf)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(data, buf.Bytes()) {
		t.Fatal("retrieved data does not match")
	}
}

func TestStore_Deduplication(t *testing.T) {
	s := tempStore(t)
	data := []byte("duplicate content")

	hash1, _, _ := s.Put(bytes.NewReader(data))
	hash2, _, _ := s.Put(bytes.NewReader(data))

	if hash1 != hash2 {
		t.Fatal("same content should produce same hash")
	}

	// Count chunk files on disk — should be 1, not 2
	entries, _ := os.ReadDir(filepath.Join(s.dir, hash1[:2]))
	count := 0
	for range entries {
		count++
	}
	if count != 1 {
		t.Fatalf("expected 1 chunk file (dedup), got %d", count)
	}
}

func TestStore_GetNotFound(t *testing.T) {
	s := tempStore(t)
	var buf bytes.Buffer
	err := s.Get("nonexistent_hash", &buf)
	if err == nil {
		t.Fatal("expected error for missing hash")
	}
}

func TestStore_Delete(t *testing.T) {
	s := tempStore(t)
	data := []byte("to be deleted")
	fileHash, _, _ := s.Put(bytes.NewReader(data))

	if err := s.Delete(fileHash); err != nil {
		t.Fatal(err)
	}

	var buf bytes.Buffer
	err := s.Get(fileHash, &buf)
	if err == nil {
		t.Fatal("expected error after deletion")
	}
}

func TestStore_LargeFile(t *testing.T) {
	s := tempStore(t)
	// 10KB file with 1KB chunks → 10 chunks
	data := make([]byte, 10*1024)
	for i := range data {
		data[i] = byte(i % 256)
	}

	fileHash, size, err := s.Put(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	if size != int64(len(data)) {
		t.Fatalf("expected size %d, got %d", len(data), size)
	}

	var buf bytes.Buffer
	err = s.Get(fileHash, &buf)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(data, buf.Bytes()) {
		t.Fatal("large file round-trip failed")
	}
}
```

- [ ] **Step 6: Run test to verify it fails**

```bash
go test ./internal/storage/ -v -run TestStore
```

Expected: FAIL — `NewStore` not defined.

- [ ] **Step 7: Implement store**

Create `internal/storage/store.go`:

```go
package storage

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

var ErrNotFound = errors.New("not found in store")

// FileManifest maps a file hash to its ordered list of chunk hashes.
type FileManifest struct {
	Chunks   []string `json:"chunks"`
	TotalSize int64   `json:"total_size"`
}

// Store is a content-addressable file store.
// Files are split into chunks. Each chunk is stored by its SHA-256 hash.
// A manifest file maps the overall file hash to its chunk list.
type Store struct {
	dir       string
	chunker   *Chunker
}

func NewStore(dir string, chunkSize int) (*Store, error) {
	if err := os.MkdirAll(dir, 0755); err != nil {
		return nil, fmt.Errorf("create store dir: %w", err)
	}
	return &Store{
		dir:     dir,
		chunker: NewChunker(chunkSize),
	}, nil
}

// Put reads all data from r, chunks it, stores each chunk, and writes a manifest.
// Returns the file-level hash (SHA-256 of the full content), total size, and any error.
func (s *Store) Put(r io.Reader) (string, int64, error) {
	// Read all data to compute file hash and chunk it
	data, err := io.ReadAll(r)
	if err != nil {
		return "", 0, fmt.Errorf("read data: %w", err)
	}

	fileHashBytes := sha256.Sum256(data)
	fileHash := hex.EncodeToString(fileHashBytes[:])

	chunks, err := s.chunker.Chunk(bytes.NewReader(data))
	if err != nil {
		return "", 0, fmt.Errorf("chunk data: %w", err)
	}

	// Store each chunk
	for _, chunk := range chunks {
		if err := s.putChunk(chunk.Hash, chunk.Data); err != nil {
			return "", 0, fmt.Errorf("store chunk %s: %w", chunk.Hash, err)
		}
	}

	// Write manifest
	manifest := FileManifest{
		TotalSize: int64(len(data)),
	}
	for _, chunk := range chunks {
		manifest.Chunks = append(manifest.Chunks, chunk.Hash)
	}
	if err := s.putManifest(fileHash, manifest); err != nil {
		return "", 0, fmt.Errorf("write manifest: %w", err)
	}

	return fileHash, int64(len(data)), nil
}

// Get retrieves a file by hash and writes its content to w.
func (s *Store) Get(fileHash string, w io.Writer) error {
	manifest, err := s.getManifest(fileHash)
	if err != nil {
		return err
	}

	for _, chunkHash := range manifest.Chunks {
		data, err := s.getChunk(chunkHash)
		if err != nil {
			return fmt.Errorf("read chunk %s: %w", chunkHash, err)
		}
		if _, err := w.Write(data); err != nil {
			return fmt.Errorf("write chunk: %w", err)
		}
	}
	return nil
}

// Delete removes a file manifest and its chunks from the store.
// NOTE: This does not handle reference counting. If chunks are shared via
// deduplication, deleting one file may remove chunks still used by another.
// TODO(chunk2): Add reference counting before using in production.
func (s *Store) Delete(fileHash string) error {
	manifest, err := s.getManifest(fileHash)
	if err != nil {
		return err
	}
	for _, chunkHash := range manifest.Chunks {
		os.Remove(s.chunkPath(chunkHash))
	}
	return os.Remove(s.manifestPath(fileHash))
}

func (s *Store) chunkPath(hash string) string {
	// Use first 2 chars as subdirectory to avoid too many files in one dir
	return filepath.Join(s.dir, hash[:2], hash)
}

func (s *Store) manifestPath(hash string) string {
	return filepath.Join(s.dir, hash[:2], hash+".manifest")
}

func (s *Store) putChunk(hash string, data []byte) error {
	path := s.chunkPath(hash)
	if _, err := os.Stat(path); err == nil {
		return nil // Already exists (deduplication)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	return os.WriteFile(path, data, 0644)
}

func (s *Store) getChunk(hash string) ([]byte, error) {
	data, err := os.ReadFile(s.chunkPath(hash))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("%w: chunk %s", ErrNotFound, hash)
		}
		return nil, err
	}
	return data, nil
}

func (s *Store) putManifest(hash string, m FileManifest) error {
	path := s.manifestPath(hash)
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	data, err := json.Marshal(m)
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0644)
}

func (s *Store) getManifest(hash string) (FileManifest, error) {
	data, err := os.ReadFile(s.manifestPath(hash))
	if err != nil {
		if os.IsNotExist(err) {
			return FileManifest{}, fmt.Errorf("%w: file %s", ErrNotFound, hash)
		}
		return FileManifest{}, err
	}
	var m FileManifest
	if err := json.Unmarshal(data, &m); err != nil {
		return FileManifest{}, err
	}
	return m, nil
}

```

- [ ] **Step 8: Run tests to verify they pass**

```bash
go test ./internal/storage/ -v
```

Expected: all chunker and store tests PASS.

- [ ] **Step 9: Commit**

```bash
git add internal/storage/
git commit -m "feat: add content-addressable storage engine with chunking"
```

---

### Task 3: SQLite Metadata Database

**Files:**
- Create: `internal/metadata/schema.sql`
- Create: `internal/metadata/db.go`
- Create: `internal/metadata/db_test.go`

- [ ] **Step 1: Write database schema**

Create `internal/metadata/schema.sql`:

```sql
-- Users
CREATE TABLE IF NOT EXISTS users (
    id          TEXT PRIMARY KEY,
    username    TEXT NOT NULL UNIQUE,
    email       TEXT NOT NULL UNIQUE,
    password    TEXT NOT NULL,
    role        TEXT NOT NULL DEFAULT 'user' CHECK(role IN ('admin', 'user')),
    quota_bytes INTEGER NOT NULL DEFAULT 0,  -- 0 = unlimited
    created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Files and folders
CREATE TABLE IF NOT EXISTS files (
    id            TEXT PRIMARY KEY,
    parent_id     TEXT REFERENCES files(id) ON DELETE CASCADE,
    owner_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name          TEXT NOT NULL,
    is_dir        INTEGER NOT NULL DEFAULT 0,
    size          INTEGER NOT NULL DEFAULT 0,
    content_hash  TEXT,         -- SHA-256 hash of content (NULL for dirs)
    mime_type     TEXT,
    created_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at    DATETIME,     -- soft delete (trash bin)
    UNIQUE(parent_id, name, owner_id)
);
CREATE INDEX IF NOT EXISTS idx_files_parent ON files(parent_id);
CREATE INDEX IF NOT EXISTS idx_files_owner ON files(owner_id);
CREATE INDEX IF NOT EXISTS idx_files_deleted ON files(deleted_at);

-- File versions
CREATE TABLE IF NOT EXISTS versions (
    id           TEXT PRIMARY KEY,
    file_id      TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    version_num  INTEGER NOT NULL,
    content_hash TEXT NOT NULL,
    patch_hash   TEXT,         -- hash of delta patch (NULL for first version)
    size         INTEGER NOT NULL,
    created_by   TEXT NOT NULL REFERENCES users(id),
    created_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(file_id, version_num)
);
CREATE INDEX IF NOT EXISTS idx_versions_file ON versions(file_id);

-- Team folders
CREATE TABLE IF NOT EXISTS team_folders (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Team folder permissions
CREATE TABLE IF NOT EXISTS team_permissions (
    id             TEXT PRIMARY KEY,
    team_folder_id TEXT NOT NULL REFERENCES team_folders(id) ON DELETE CASCADE,
    user_id        TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    permission     TEXT NOT NULL CHECK(permission IN ('read', 'write')),
    UNIQUE(team_folder_id, user_id)
);

-- Connected devices
CREATE TABLE IF NOT EXISTS devices (
    id          TEXT PRIMARY KEY,
    user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    platform    TEXT NOT NULL,
    last_seen   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_devices_user ON devices(user_id);

-- Activity log
CREATE TABLE IF NOT EXISTS activity_log (
    id          TEXT PRIMARY KEY,
    user_id     TEXT REFERENCES users(id) ON DELETE SET NULL,
    action      TEXT NOT NULL,
    resource    TEXT NOT NULL,
    resource_id TEXT,
    details     TEXT,          -- JSON details
    ip_address  TEXT,
    created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_activity_user ON activity_log(user_id);
CREATE INDEX IF NOT EXISTS idx_activity_created ON activity_log(created_at);

-- Share links
CREATE TABLE IF NOT EXISTS share_links (
    id             TEXT PRIMARY KEY,
    file_id        TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    token          TEXT NOT NULL UNIQUE,
    password_hash  TEXT,
    expires_at     DATETIME,
    max_downloads  INTEGER,
    download_count INTEGER NOT NULL DEFAULT 0,
    created_by     TEXT NOT NULL REFERENCES users(id),
    created_at     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_shares_token ON share_links(token);

-- Retention policies (per team folder or global)
CREATE TABLE IF NOT EXISTS retention_policies (
    id              TEXT PRIMARY KEY,
    team_folder_id  TEXT REFERENCES team_folders(id) ON DELETE CASCADE,
    daily_days      INTEGER NOT NULL DEFAULT 7,
    weekly_weeks    INTEGER NOT NULL DEFAULT 4,
    monthly_months  INTEGER NOT NULL DEFAULT 6,
    yearly_keep     INTEGER NOT NULL DEFAULT 1,  -- 1 = keep forever, 0 = delete
    max_versions    INTEGER NOT NULL DEFAULT 32,
    rotation_algo   TEXT NOT NULL DEFAULT 'fifo' CHECK(rotation_algo IN ('fifo', 'intelliversioning')),
    UNIQUE(team_folder_id)
);

-- Sync state tracking (per device per file)
CREATE TABLE IF NOT EXISTS sync_state (
    device_id    TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    file_id      TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    version_num  INTEGER NOT NULL,
    synced_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY(device_id, file_id)
);
```

- [ ] **Step 2: Write db.go with connection and migration**

Create `internal/metadata/db.go`:

```go
package metadata

import (
	"database/sql"
	_ "embed"
	"fmt"

	_ "modernc.org/sqlite"
)

//go:embed schema.sql
var schemaSQL string

type DB struct {
	conn *sql.DB
}

func Open(path string) (*DB, error) {
	conn, err := sql.Open("sqlite", path+"?_journal_mode=WAL&_busy_timeout=5000&_foreign_keys=ON")
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}
	// SQLite supports concurrent readers in WAL mode, but we use a single
	// connection to avoid "database is locked" errors during writes.
	// For read-heavy workloads, consider increasing this with proper retry logic.
	conn.SetMaxOpenConns(1)

	db := &DB{conn: conn}
	if err := db.migrate(); err != nil {
		conn.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return db, nil
}

func (db *DB) Close() error {
	return db.conn.Close()
}

func (db *DB) Conn() *sql.DB {
	return db.conn
}

func (db *DB) migrate() error {
	_, err := db.conn.Exec(schemaSQL)
	return err
}
```

- [ ] **Step 3: Write db test**

Create `internal/metadata/db_test.go`:

```go
package metadata

import (
	"path/filepath"
	"testing"
)

func testDB(t *testing.T) *DB {
	t.Helper()
	path := filepath.Join(t.TempDir(), "test.db")
	db, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

func TestDB_Open(t *testing.T) {
	db := testDB(t)
	// Verify tables exist
	tables := []string{"users", "files", "versions", "team_folders",
		"team_permissions", "devices", "activity_log", "share_links",
		"retention_policies", "sync_state"}
	for _, table := range tables {
		var name string
		err := db.conn.QueryRow(
			"SELECT name FROM sqlite_master WHERE type='table' AND name=?", table,
		).Scan(&name)
		if err != nil {
			t.Fatalf("table %s not found: %v", table, err)
		}
	}
}

func TestDB_WALMode(t *testing.T) {
	db := testDB(t)
	var mode string
	db.conn.QueryRow("PRAGMA journal_mode").Scan(&mode)
	if mode != "wal" {
		t.Fatalf("expected WAL mode, got %s", mode)
	}
}

func TestDB_ForeignKeys(t *testing.T) {
	db := testDB(t)
	var fk int
	db.conn.QueryRow("PRAGMA foreign_keys").Scan(&fk)
	if fk != 1 {
		t.Fatal("foreign keys not enabled")
	}
}
```

- [ ] **Step 4: Install SQLite dependency and run tests**

```bash
cd "/Users/niel/Development/Sync & Backup"
go get modernc.org/sqlite
go test ./internal/metadata/ -v -run TestDB
```

Expected: all 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/metadata/schema.sql internal/metadata/db.go internal/metadata/db_test.go go.mod go.sum
git commit -m "feat: add SQLite metadata database with schema and migrations"
```

---

### Task 4: User CRUD Operations

**Files:**
- Create: `internal/metadata/users.go`
- Create: `internal/metadata/users_test.go`

- [ ] **Step 1: Write users test**

Create `internal/metadata/users_test.go`:

```go
package metadata

import (
	"testing"
)

func TestUsers_Create(t *testing.T) {
	db := testDB(t)
	user, err := db.CreateUser("alice", "alice@example.com", "hashed_pw", "admin")
	if err != nil {
		t.Fatal(err)
	}
	if user.Username != "alice" {
		t.Fatalf("expected username 'alice', got '%s'", user.Username)
	}
	if user.Role != "admin" {
		t.Fatalf("expected role 'admin', got '%s'", user.Role)
	}
	if user.ID == "" {
		t.Fatal("expected non-empty ID")
	}
}

func TestUsers_DuplicateUsername(t *testing.T) {
	db := testDB(t)
	db.CreateUser("alice", "alice@example.com", "pw", "user")
	_, err := db.CreateUser("alice", "alice2@example.com", "pw", "user")
	if err == nil {
		t.Fatal("expected error for duplicate username")
	}
}

func TestUsers_GetByID(t *testing.T) {
	db := testDB(t)
	created, _ := db.CreateUser("bob", "bob@example.com", "pw", "user")
	got, err := db.GetUserByID(created.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Username != "bob" {
		t.Fatalf("expected 'bob', got '%s'", got.Username)
	}
}

func TestUsers_GetByUsername(t *testing.T) {
	db := testDB(t)
	db.CreateUser("charlie", "charlie@example.com", "pw", "user")
	got, err := db.GetUserByUsername("charlie")
	if err != nil {
		t.Fatal(err)
	}
	if got.Email != "charlie@example.com" {
		t.Fatalf("expected 'charlie@example.com', got '%s'", got.Email)
	}
}

func TestUsers_List(t *testing.T) {
	db := testDB(t)
	db.CreateUser("user1", "u1@example.com", "pw", "user")
	db.CreateUser("user2", "u2@example.com", "pw", "user")
	db.CreateUser("user3", "u3@example.com", "pw", "admin")

	users, err := db.ListUsers()
	if err != nil {
		t.Fatal(err)
	}
	if len(users) != 3 {
		t.Fatalf("expected 3 users, got %d", len(users))
	}
}

func TestUsers_Update(t *testing.T) {
	db := testDB(t)
	user, _ := db.CreateUser("dave", "dave@example.com", "pw", "user")
	user.Email = "newemail@example.com"
	user.QuotaBytes = 1024 * 1024 * 1024 // 1GB
	err := db.UpdateUser(user)
	if err != nil {
		t.Fatal(err)
	}
	got, _ := db.GetUserByID(user.ID)
	if got.Email != "newemail@example.com" {
		t.Fatalf("email not updated")
	}
	if got.QuotaBytes != 1024*1024*1024 {
		t.Fatalf("quota not updated")
	}
}

func TestUsers_Delete(t *testing.T) {
	db := testDB(t)
	user, _ := db.CreateUser("eve", "eve@example.com", "pw", "user")
	err := db.DeleteUser(user.ID)
	if err != nil {
		t.Fatal(err)
	}
	_, err = db.GetUserByID(user.ID)
	if err == nil {
		t.Fatal("expected error after deletion")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/metadata/ -v -run TestUsers
```

Expected: FAIL — `CreateUser` not defined.

- [ ] **Step 3: Implement users.go**

Create `internal/metadata/users.go`:

```go
package metadata

import (
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

var ErrNotFound = errors.New("not found")

type User struct {
	ID         string
	Username   string
	Email      string
	Password   string
	Role       string
	QuotaBytes int64
	CreatedAt  time.Time
	UpdatedAt  time.Time
}

func (db *DB) CreateUser(username, email, password, role string) (*User, error) {
	user := &User{
		ID:        uuid.New().String(),
		Username:  username,
		Email:     email,
		Password:  password,
		Role:      role,
		CreatedAt: time.Now().UTC(),
		UpdatedAt: time.Now().UTC(),
	}
	_, err := db.conn.Exec(
		`INSERT INTO users (id, username, email, password, role, created_at, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?)`,
		user.ID, user.Username, user.Email, user.Password, user.Role,
		user.CreatedAt, user.UpdatedAt,
	)
	if err != nil {
		return nil, fmt.Errorf("create user: %w", err)
	}
	return user, nil
}

func (db *DB) GetUserByID(id string) (*User, error) {
	return db.scanUser(db.conn.QueryRow(
		`SELECT id, username, email, password, role, quota_bytes, created_at, updated_at
		 FROM users WHERE id = ?`, id,
	))
}

func (db *DB) GetUserByUsername(username string) (*User, error) {
	return db.scanUser(db.conn.QueryRow(
		`SELECT id, username, email, password, role, quota_bytes, created_at, updated_at
		 FROM users WHERE username = ?`, username,
	))
}

func (db *DB) ListUsers() ([]User, error) {
	rows, err := db.conn.Query(
		`SELECT id, username, email, password, role, quota_bytes, created_at, updated_at
		 FROM users ORDER BY username`,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var users []User
	for rows.Next() {
		var u User
		if err := rows.Scan(&u.ID, &u.Username, &u.Email, &u.Password,
			&u.Role, &u.QuotaBytes, &u.CreatedAt, &u.UpdatedAt); err != nil {
			return nil, err
		}
		users = append(users, u)
	}
	return users, rows.Err()
}

func (db *DB) UpdateUser(user *User) error {
	user.UpdatedAt = time.Now().UTC()
	result, err := db.conn.Exec(
		`UPDATE users SET username=?, email=?, password=?, role=?,
		 quota_bytes=?, updated_at=? WHERE id=?`,
		user.Username, user.Email, user.Password, user.Role,
		user.QuotaBytes, user.UpdatedAt, user.ID,
	)
	if err != nil {
		return fmt.Errorf("update user: %w", err)
	}
	n, _ := result.RowsAffected()
	if n == 0 {
		return fmt.Errorf("%w: user %s", ErrNotFound, user.ID)
	}
	return nil
}

func (db *DB) DeleteUser(id string) error {
	result, err := db.conn.Exec(`DELETE FROM users WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("delete user: %w", err)
	}
	n, _ := result.RowsAffected()
	if n == 0 {
		return fmt.Errorf("%w: user %s", ErrNotFound, id)
	}
	return nil
}

func (db *DB) scanUser(row *sql.Row) (*User, error) {
	var u User
	err := row.Scan(&u.ID, &u.Username, &u.Email, &u.Password,
		&u.Role, &u.QuotaBytes, &u.CreatedAt, &u.UpdatedAt)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return &u, nil
}
```

- [ ] **Step 4: Install uuid dependency and run tests**

```bash
go get github.com/google/uuid
go test ./internal/metadata/ -v -run TestUsers
```

Expected: all 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/metadata/users.go internal/metadata/users_test.go go.mod go.sum
git commit -m "feat: add user CRUD operations"
```

---

### Task 5: File and Folder CRUD Operations

**Files:**
- Create: `internal/metadata/files.go`
- Create: `internal/metadata/files_test.go`

- [ ] **Step 1: Write files test**

Create `internal/metadata/files_test.go`:

```go
package metadata

import (
	"testing"
)

func seedUser(t *testing.T, db *DB) *User {
	t.Helper()
	u, err := db.CreateUser("testuser", "test@example.com", "pw", "user")
	if err != nil {
		t.Fatal(err)
	}
	return u
}

func TestFiles_CreateFolder(t *testing.T) {
	db := testDB(t)
	u := seedUser(t, db)

	folder, err := db.CreateFile("", u.ID, "Documents", true, 0, "", "")
	if err != nil {
		t.Fatal(err)
	}
	if folder.Name != "Documents" {
		t.Fatalf("expected 'Documents', got '%s'", folder.Name)
	}
	if !folder.IsDir {
		t.Fatal("expected is_dir = true")
	}
}

func TestFiles_CreateFile(t *testing.T) {
	db := testDB(t)
	u := seedUser(t, db)
	folder, _ := db.CreateFile("", u.ID, "Documents", true, 0, "", "")

	file, err := db.CreateFile(folder.ID, u.ID, "report.pdf", false, 1024, "abc123", "application/pdf")
	if err != nil {
		t.Fatal(err)
	}
	if file.ParentID != folder.ID {
		t.Fatalf("expected parent '%s', got '%s'", folder.ID, file.ParentID)
	}
	if file.Size != 1024 {
		t.Fatalf("expected size 1024, got %d", file.Size)
	}
}

func TestFiles_ListChildren(t *testing.T) {
	db := testDB(t)
	u := seedUser(t, db)
	folder, _ := db.CreateFile("", u.ID, "Root", true, 0, "", "")
	db.CreateFile(folder.ID, u.ID, "a.txt", false, 100, "h1", "text/plain")
	db.CreateFile(folder.ID, u.ID, "b.txt", false, 200, "h2", "text/plain")
	db.CreateFile(folder.ID, u.ID, "subfolder", true, 0, "", "")

	children, err := db.ListChildren(folder.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(children) != 3 {
		t.Fatalf("expected 3 children, got %d", len(children))
	}
}

func TestFiles_GetByID(t *testing.T) {
	db := testDB(t)
	u := seedUser(t, db)
	created, _ := db.CreateFile("", u.ID, "test.txt", false, 50, "hash", "text/plain")

	got, err := db.GetFileByID(created.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Name != "test.txt" {
		t.Fatalf("expected 'test.txt', got '%s'", got.Name)
	}
}

func TestFiles_Move(t *testing.T) {
	db := testDB(t)
	u := seedUser(t, db)
	folder1, _ := db.CreateFile("", u.ID, "Folder1", true, 0, "", "")
	folder2, _ := db.CreateFile("", u.ID, "Folder2", true, 0, "", "")
	file, _ := db.CreateFile(folder1.ID, u.ID, "doc.txt", false, 100, "h", "text/plain")

	err := db.MoveFile(file.ID, folder2.ID, "doc.txt")
	if err != nil {
		t.Fatal(err)
	}
	got, _ := db.GetFileByID(file.ID)
	if got.ParentID != folder2.ID {
		t.Fatal("file not moved to Folder2")
	}
}

func TestFiles_SoftDelete(t *testing.T) {
	db := testDB(t)
	u := seedUser(t, db)
	file, _ := db.CreateFile("", u.ID, "trash.txt", false, 100, "h", "text/plain")

	err := db.SoftDeleteFile(file.ID)
	if err != nil {
		t.Fatal(err)
	}
	got, _ := db.GetFileByID(file.ID)
	if got.DeletedAt == nil {
		t.Fatal("expected deleted_at to be set")
	}

	// Should not appear in normal listings
	children, _ := db.ListChildren("")
	for _, c := range children {
		if c.ID == file.ID {
			t.Fatal("soft-deleted file should not appear in listings")
		}
	}
}

func TestFiles_Rename(t *testing.T) {
	db := testDB(t)
	u := seedUser(t, db)
	file, _ := db.CreateFile("", u.ID, "old.txt", false, 100, "h", "text/plain")

	err := db.MoveFile(file.ID, "", "new.txt")
	if err != nil {
		t.Fatal(err)
	}
	got, _ := db.GetFileByID(file.ID)
	if got.Name != "new.txt" {
		t.Fatalf("expected 'new.txt', got '%s'", got.Name)
	}
}

func TestFiles_StorageUsed(t *testing.T) {
	db := testDB(t)
	u := seedUser(t, db)
	db.CreateFile("", u.ID, "a.txt", false, 1000, "h1", "text/plain")
	db.CreateFile("", u.ID, "b.txt", false, 2000, "h2", "text/plain")

	used, err := db.StorageUsedByUser(u.ID)
	if err != nil {
		t.Fatal(err)
	}
	if used != 3000 {
		t.Fatalf("expected 3000 bytes, got %d", used)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/metadata/ -v -run TestFiles
```

Expected: FAIL — `CreateFile` not defined.

- [ ] **Step 3: Implement files.go**

Create `internal/metadata/files.go`:

```go
package metadata

import (
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

type File struct {
	ID          string
	ParentID    string
	OwnerID     string
	Name        string
	IsDir       bool
	Size        int64
	ContentHash string
	MimeType    string
	CreatedAt   time.Time
	UpdatedAt   time.Time
	DeletedAt   *time.Time
}

func (db *DB) CreateFile(parentID, ownerID, name string, isDir bool, size int64, contentHash, mimeType string) (*File, error) {
	file := &File{
		ID:          uuid.New().String(),
		ParentID:    parentID,
		OwnerID:     ownerID,
		Name:        name,
		IsDir:       isDir,
		Size:        size,
		ContentHash: contentHash,
		MimeType:    mimeType,
		CreatedAt:   time.Now().UTC(),
		UpdatedAt:   time.Now().UTC(),
	}

	var parentVal interface{}
	if parentID != "" {
		parentVal = parentID
	}

	_, err := db.conn.Exec(
		`INSERT INTO files (id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type, created_at, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		file.ID, parentVal, file.OwnerID, file.Name, boolToInt(file.IsDir),
		file.Size, nullString(file.ContentHash), nullString(file.MimeType),
		file.CreatedAt, file.UpdatedAt,
	)
	if err != nil {
		return nil, fmt.Errorf("create file: %w", err)
	}
	return file, nil
}

func (db *DB) GetFileByID(id string) (*File, error) {
	row := db.conn.QueryRow(
		`SELECT id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type,
		        created_at, updated_at, deleted_at
		 FROM files WHERE id = ?`, id,
	)
	return scanFile(row)
}

func (db *DB) ListChildren(parentID string) ([]File, error) {
	var rows *sql.Rows
	var err error
	if parentID == "" {
		rows, err = db.conn.Query(
			`SELECT id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type,
			        created_at, updated_at, deleted_at
			 FROM files WHERE parent_id IS NULL AND deleted_at IS NULL
			 ORDER BY is_dir DESC, name`,
		)
	} else {
		rows, err = db.conn.Query(
			`SELECT id, parent_id, owner_id, name, is_dir, size, content_hash, mime_type,
			        created_at, updated_at, deleted_at
			 FROM files WHERE parent_id = ? AND deleted_at IS NULL
			 ORDER BY is_dir DESC, name`,
			parentID,
		)
	}
	// NOTE: For multi-user, callers should filter by owner_id.
	// The REST API layer handles this filtering.
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var files []File
	for rows.Next() {
		f, err := scanFileRow(rows)
		if err != nil {
			return nil, err
		}
		files = append(files, *f)
	}
	return files, rows.Err()
}

func (db *DB) MoveFile(id, newParentID, newName string) error {
	var parentVal interface{}
	if newParentID != "" {
		parentVal = newParentID
	}
	result, err := db.conn.Exec(
		`UPDATE files SET parent_id = ?, name = ?, updated_at = ? WHERE id = ?`,
		parentVal, newName, time.Now().UTC(), id,
	)
	if err != nil {
		return fmt.Errorf("move file: %w", err)
	}
	n, _ := result.RowsAffected()
	if n == 0 {
		return fmt.Errorf("%w: file %s", ErrNotFound, id)
	}
	return nil
}

func (db *DB) SoftDeleteFile(id string) error {
	now := time.Now().UTC()
	result, err := db.conn.Exec(
		`UPDATE files SET deleted_at = ?, updated_at = ? WHERE id = ?`,
		now, now, id,
	)
	if err != nil {
		return fmt.Errorf("soft delete: %w", err)
	}
	n, _ := result.RowsAffected()
	if n == 0 {
		return fmt.Errorf("%w: file %s", ErrNotFound, id)
	}
	return nil
}

func (db *DB) UpdateFileContent(id, contentHash string, size int64) error {
	result, err := db.conn.Exec(
		`UPDATE files SET content_hash = ?, size = ?, updated_at = ? WHERE id = ?`,
		contentHash, size, time.Now().UTC(), id,
	)
	if err != nil {
		return fmt.Errorf("update file content: %w", err)
	}
	n, _ := result.RowsAffected()
	if n == 0 {
		return fmt.Errorf("%w: file %s", ErrNotFound, id)
	}
	return nil
}

func (db *DB) StorageUsedByUser(userID string) (int64, error) {
	var total sql.NullInt64
	err := db.conn.QueryRow(
		`SELECT COALESCE(SUM(size), 0) FROM files WHERE owner_id = ? AND deleted_at IS NULL`,
		userID,
	).Scan(&total)
	if err != nil {
		return 0, err
	}
	return total.Int64, nil
}

func scanFile(row *sql.Row) (*File, error) {
	var f File
	var parentID, contentHash, mimeType sql.NullString
	var deletedAt sql.NullTime
	var isDir int

	err := row.Scan(&f.ID, &parentID, &f.OwnerID, &f.Name, &isDir,
		&f.Size, &contentHash, &mimeType, &f.CreatedAt, &f.UpdatedAt, &deletedAt)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	f.ParentID = parentID.String
	f.ContentHash = contentHash.String
	f.MimeType = mimeType.String
	f.IsDir = isDir == 1
	if deletedAt.Valid {
		f.DeletedAt = &deletedAt.Time
	}
	return &f, nil
}

func scanFileRow(rows *sql.Rows) (*File, error) {
	var f File
	var parentID, contentHash, mimeType sql.NullString
	var deletedAt sql.NullTime
	var isDir int

	err := rows.Scan(&f.ID, &parentID, &f.OwnerID, &f.Name, &isDir,
		&f.Size, &contentHash, &mimeType, &f.CreatedAt, &f.UpdatedAt, &deletedAt)
	if err != nil {
		return nil, err
	}
	f.ParentID = parentID.String
	f.ContentHash = contentHash.String
	f.MimeType = mimeType.String
	f.IsDir = isDir == 1
	if deletedAt.Valid {
		f.DeletedAt = &deletedAt.Time
	}
	return &f, nil
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func nullString(s string) interface{} {
	if s == "" {
		return nil
	}
	return s
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
go test ./internal/metadata/ -v -run TestFiles
```

Expected: all 8 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/metadata/files.go internal/metadata/files_test.go
git commit -m "feat: add file and folder CRUD operations"
```

---

### Task 6: Team Folder and Permission Operations

**Files:**
- Create: `internal/metadata/teams.go`
- Create: `internal/metadata/teams_test.go`

- [ ] **Step 1: Write teams test**

Create `internal/metadata/teams_test.go`:

```go
package metadata

import (
	"testing"
)

func TestTeams_Create(t *testing.T) {
	db := testDB(t)
	tf, err := db.CreateTeamFolder("Marketing")
	if err != nil {
		t.Fatal(err)
	}
	if tf.Name != "Marketing" {
		t.Fatalf("expected 'Marketing', got '%s'", tf.Name)
	}
}

func TestTeams_DuplicateName(t *testing.T) {
	db := testDB(t)
	db.CreateTeamFolder("Marketing")
	_, err := db.CreateTeamFolder("Marketing")
	if err == nil {
		t.Fatal("expected error for duplicate name")
	}
}

func TestTeams_List(t *testing.T) {
	db := testDB(t)
	db.CreateTeamFolder("Marketing")
	db.CreateTeamFolder("Development")
	folders, err := db.ListTeamFolders()
	if err != nil {
		t.Fatal(err)
	}
	if len(folders) != 2 {
		t.Fatalf("expected 2 folders, got %d", len(folders))
	}
}

func TestTeams_SetPermission(t *testing.T) {
	db := testDB(t)
	tf, _ := db.CreateTeamFolder("Marketing")
	u, _ := db.CreateUser("alice", "a@example.com", "pw", "user")

	err := db.SetTeamPermission(tf.ID, u.ID, "write")
	if err != nil {
		t.Fatal(err)
	}

	perm, err := db.GetTeamPermission(tf.ID, u.ID)
	if err != nil {
		t.Fatal(err)
	}
	if perm != "write" {
		t.Fatalf("expected 'write', got '%s'", perm)
	}
}

func TestTeams_UpdatePermission(t *testing.T) {
	db := testDB(t)
	tf, _ := db.CreateTeamFolder("Dev")
	u, _ := db.CreateUser("bob", "b@example.com", "pw", "user")

	db.SetTeamPermission(tf.ID, u.ID, "write")
	db.SetTeamPermission(tf.ID, u.ID, "read") // update

	perm, _ := db.GetTeamPermission(tf.ID, u.ID)
	if perm != "read" {
		t.Fatalf("expected 'read' after update, got '%s'", perm)
	}
}

func TestTeams_ListPermissions(t *testing.T) {
	db := testDB(t)
	tf, _ := db.CreateTeamFolder("Design")
	u1, _ := db.CreateUser("u1", "u1@example.com", "pw", "user")
	u2, _ := db.CreateUser("u2", "u2@example.com", "pw", "user")

	db.SetTeamPermission(tf.ID, u1.ID, "read")
	db.SetTeamPermission(tf.ID, u2.ID, "write")

	perms, err := db.ListTeamPermissions(tf.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(perms) != 2 {
		t.Fatalf("expected 2 permissions, got %d", len(perms))
	}
}

func TestTeams_UserFolders(t *testing.T) {
	db := testDB(t)
	tf1, _ := db.CreateTeamFolder("Marketing")
	tf2, _ := db.CreateTeamFolder("Development")
	u, _ := db.CreateUser("alice", "a@example.com", "pw", "user")

	db.SetTeamPermission(tf1.ID, u.ID, "read")
	db.SetTeamPermission(tf2.ID, u.ID, "write")

	folders, err := db.ListUserTeamFolders(u.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(folders) != 2 {
		t.Fatalf("expected 2 folders for user, got %d", len(folders))
	}
}

func TestTeams_RemovePermission(t *testing.T) {
	db := testDB(t)
	tf, _ := db.CreateTeamFolder("Team")
	u, _ := db.CreateUser("user", "u@example.com", "pw", "user")

	db.SetTeamPermission(tf.ID, u.ID, "read")
	err := db.RemoveTeamPermission(tf.ID, u.ID)
	if err != nil {
		t.Fatal(err)
	}

	_, err = db.GetTeamPermission(tf.ID, u.ID)
	if err == nil {
		t.Fatal("expected error after removing permission")
	}
}

func TestTeams_Delete(t *testing.T) {
	db := testDB(t)
	tf, _ := db.CreateTeamFolder("ToDelete")
	err := db.DeleteTeamFolder(tf.ID)
	if err != nil {
		t.Fatal(err)
	}
	folders, _ := db.ListTeamFolders()
	if len(folders) != 0 {
		t.Fatal("expected 0 folders after deletion")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/metadata/ -v -run TestTeams
```

Expected: FAIL — `CreateTeamFolder` not defined.

- [ ] **Step 3: Implement teams.go**

Create `internal/metadata/teams.go`:

```go
package metadata

import (
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

type TeamFolder struct {
	ID        string
	Name      string
	CreatedAt time.Time
}

type TeamPermission struct {
	ID           string
	TeamFolderID string
	UserID       string
	Permission   string
}

func (db *DB) CreateTeamFolder(name string) (*TeamFolder, error) {
	tf := &TeamFolder{
		ID:        uuid.New().String(),
		Name:      name,
		CreatedAt: time.Now().UTC(),
	}
	_, err := db.conn.Exec(
		`INSERT INTO team_folders (id, name, created_at) VALUES (?, ?, ?)`,
		tf.ID, tf.Name, tf.CreatedAt,
	)
	if err != nil {
		return nil, fmt.Errorf("create team folder: %w", err)
	}
	return tf, nil
}

func (db *DB) ListTeamFolders() ([]TeamFolder, error) {
	rows, err := db.conn.Query(
		`SELECT id, name, created_at FROM team_folders ORDER BY name`,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var folders []TeamFolder
	for rows.Next() {
		var tf TeamFolder
		if err := rows.Scan(&tf.ID, &tf.Name, &tf.CreatedAt); err != nil {
			return nil, err
		}
		folders = append(folders, tf)
	}
	return folders, rows.Err()
}

func (db *DB) DeleteTeamFolder(id string) error {
	_, err := db.conn.Exec(`DELETE FROM team_folders WHERE id = ?`, id)
	return err
}

func (db *DB) SetTeamPermission(teamFolderID, userID, permission string) error {
	_, err := db.conn.Exec(
		`INSERT INTO team_permissions (id, team_folder_id, user_id, permission)
		 VALUES (?, ?, ?, ?)
		 ON CONFLICT(team_folder_id, user_id) DO UPDATE SET permission = excluded.permission`,
		uuid.New().String(), teamFolderID, userID, permission,
	)
	return err
}

func (db *DB) GetTeamPermission(teamFolderID, userID string) (string, error) {
	var perm string
	err := db.conn.QueryRow(
		`SELECT permission FROM team_permissions WHERE team_folder_id = ? AND user_id = ?`,
		teamFolderID, userID,
	).Scan(&perm)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", ErrNotFound
		}
		return "", err
	}
	return perm, nil
}

func (db *DB) ListTeamPermissions(teamFolderID string) ([]TeamPermission, error) {
	rows, err := db.conn.Query(
		`SELECT id, team_folder_id, user_id, permission
		 FROM team_permissions WHERE team_folder_id = ?`, teamFolderID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var perms []TeamPermission
	for rows.Next() {
		var p TeamPermission
		if err := rows.Scan(&p.ID, &p.TeamFolderID, &p.UserID, &p.Permission); err != nil {
			return nil, err
		}
		perms = append(perms, p)
	}
	return perms, rows.Err()
}

func (db *DB) ListUserTeamFolders(userID string) ([]TeamFolder, error) {
	rows, err := db.conn.Query(
		`SELECT tf.id, tf.name, tf.created_at
		 FROM team_folders tf
		 JOIN team_permissions tp ON tf.id = tp.team_folder_id
		 WHERE tp.user_id = ?
		 ORDER BY tf.name`, userID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var folders []TeamFolder
	for rows.Next() {
		var tf TeamFolder
		if err := rows.Scan(&tf.ID, &tf.Name, &tf.CreatedAt); err != nil {
			return nil, err
		}
		folders = append(folders, tf)
	}
	return folders, rows.Err()
}

func (db *DB) RemoveTeamPermission(teamFolderID, userID string) error {
	_, err := db.conn.Exec(
		`DELETE FROM team_permissions WHERE team_folder_id = ? AND user_id = ?`,
		teamFolderID, userID,
	)
	return err
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
go test ./internal/metadata/ -v -run TestTeams
```

Expected: all 9 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/metadata/teams.go internal/metadata/teams_test.go
git commit -m "feat: add team folder and permission operations"
```

---

**End of Chunk 1**

---

## Chunk 2: Auth + User Management

### Task 7: Password Hashing

**Files:**
- Create: `internal/auth/passwords.go`
- Create: `internal/auth/passwords_test.go`

- [ ] **Step 1: Write password test**

Create `internal/auth/passwords_test.go`:

```go
package auth

import (
	"testing"
)

func TestHashPassword(t *testing.T) {
	hash, err := HashPassword("mysecretpassword")
	if err != nil {
		t.Fatal(err)
	}
	if hash == "" {
		t.Fatal("expected non-empty hash")
	}
	if hash == "mysecretpassword" {
		t.Fatal("hash should not equal plaintext")
	}
}

func TestCheckPassword_Correct(t *testing.T) {
	hash, _ := HashPassword("correcthorse")
	if !CheckPassword("correcthorse", hash) {
		t.Fatal("expected password to match")
	}
}

func TestCheckPassword_Wrong(t *testing.T) {
	hash, _ := HashPassword("correcthorse")
	if CheckPassword("wrongpassword", hash) {
		t.Fatal("expected password to not match")
	}
}

func TestHashPassword_UniqueSalts(t *testing.T) {
	h1, _ := HashPassword("same")
	h2, _ := HashPassword("same")
	if h1 == h2 {
		t.Fatal("two hashes of same password should differ (different salts)")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/auth/ -v -run TestHash
```

Expected: FAIL — `HashPassword` not defined.

- [ ] **Step 3: Implement passwords.go**

Create `internal/auth/passwords.go`:

```go
package auth

import "golang.org/x/crypto/bcrypt"

func HashPassword(password string) (string, error) {
	bytes, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return "", err
	}
	return string(bytes), nil
}

func CheckPassword(password, hash string) bool {
	err := bcrypt.CompareHashAndPassword([]byte(hash), []byte(password))
	return err == nil
}
```

- [ ] **Step 4: Install bcrypt and run tests**

```bash
go get golang.org/x/crypto/bcrypt
go test ./internal/auth/ -v -run TestHash
go test ./internal/auth/ -v -run TestCheck
```

Expected: all 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/auth/passwords.go internal/auth/passwords_test.go go.mod go.sum
git commit -m "feat: add bcrypt password hashing"
```

---

### Task 8: JWT Authentication

**Files:**
- Create: `internal/auth/auth.go`
- Create: `internal/auth/auth_test.go`

- [ ] **Step 1: Write JWT test**

Create `internal/auth/auth_test.go`:

```go
package auth

import (
	"testing"
	"time"
)

func TestGenerateTokens(t *testing.T) {
	j := NewJWT("test-secret-key-at-least-32-bytes!")
	access, refresh, err := j.GenerateTokens("user-123", "alice", "admin")
	if err != nil {
		t.Fatal(err)
	}
	if access == "" {
		t.Fatal("expected non-empty access token")
	}
	if refresh == "" {
		t.Fatal("expected non-empty refresh token")
	}
	if access == refresh {
		t.Fatal("access and refresh tokens should differ")
	}
}

func TestValidateAccessToken(t *testing.T) {
	j := NewJWT("test-secret-key-at-least-32-bytes!")
	access, _, _ := j.GenerateTokens("user-123", "alice", "admin")

	claims, err := j.ValidateAccessToken(access)
	if err != nil {
		t.Fatal(err)
	}
	if claims.UserID != "user-123" {
		t.Fatalf("expected user-123, got %s", claims.UserID)
	}
	if claims.Username != "alice" {
		t.Fatalf("expected alice, got %s", claims.Username)
	}
	if claims.Role != "admin" {
		t.Fatalf("expected admin, got %s", claims.Role)
	}
}

func TestValidateRefreshToken(t *testing.T) {
	j := NewJWT("test-secret-key-at-least-32-bytes!")
	_, refresh, _ := j.GenerateTokens("user-456", "bob", "user")

	claims, err := j.ValidateRefreshToken(refresh)
	if err != nil {
		t.Fatal(err)
	}
	if claims.UserID != "user-456" {
		t.Fatalf("expected user-456, got %s", claims.UserID)
	}
}

func TestValidateToken_Expired(t *testing.T) {
	j := NewJWT("test-secret-key-at-least-32-bytes!")
	j.accessTTL = -1 * time.Hour // expired
	access, _, _ := j.GenerateTokens("user-789", "charlie", "user")

	_, err := j.ValidateAccessToken(access)
	if err == nil {
		t.Fatal("expected error for expired token")
	}
}

func TestValidateToken_WrongSecret(t *testing.T) {
	j1 := NewJWT("secret-one-at-least-32-bytes!!!!")
	j2 := NewJWT("secret-two-at-least-32-bytes!!!!")

	access, _, _ := j1.GenerateTokens("user-1", "alice", "user")
	_, err := j2.ValidateAccessToken(access)
	if err == nil {
		t.Fatal("expected error for wrong secret")
	}
}

func TestRefreshToken_CannotBeUsedAsAccess(t *testing.T) {
	j := NewJWT("test-secret-key-at-least-32-bytes!")
	_, refresh, _ := j.GenerateTokens("user-1", "alice", "user")

	_, err := j.ValidateAccessToken(refresh)
	if err == nil {
		t.Fatal("refresh token should not validate as access token")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/auth/ -v -run TestGenerate
```

Expected: FAIL — `NewJWT` not defined.

- [ ] **Step 3: Implement auth.go**

Create `internal/auth/auth.go`:

```go
package auth

import (
	"errors"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

var (
	ErrInvalidToken = errors.New("invalid token")
	ErrExpiredToken = errors.New("expired token")
)

type Claims struct {
	UserID   string
	Username string
	Role     string
}

type JWT struct {
	secret     []byte
	accessTTL  time.Duration
	refreshTTL time.Duration
}

type tokenClaims struct {
	jwt.RegisteredClaims
	UserID   string `json:"uid"`
	Username string `json:"usr"`
	Role     string `json:"role"`
	Type     string `json:"type"` // "access" or "refresh"
}

func NewJWT(secret string) *JWT {
	return &JWT{
		secret:     []byte(secret),
		accessTTL:  15 * time.Minute,
		refreshTTL: 7 * 24 * time.Hour,
	}
}

func (j *JWT) GenerateTokens(userID, username, role string) (accessToken, refreshToken string, err error) {
	now := time.Now()

	accessClaims := tokenClaims{
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(now.Add(j.accessTTL)),
			IssuedAt:  jwt.NewNumericDate(now),
			Issuer:    "syncvault",
		},
		UserID:   userID,
		Username: username,
		Role:     role,
		Type:     "access",
	}
	access := jwt.NewWithClaims(jwt.SigningMethodHS256, accessClaims)
	accessToken, err = access.SignedString(j.secret)
	if err != nil {
		return "", "", err
	}

	refreshClaims := tokenClaims{
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(now.Add(j.refreshTTL)),
			IssuedAt:  jwt.NewNumericDate(now),
			Issuer:    "syncvault",
		},
		UserID:   userID,
		Username: username,
		Role:     role,
		Type:     "refresh",
	}
	refresh := jwt.NewWithClaims(jwt.SigningMethodHS256, refreshClaims)
	refreshToken, err = refresh.SignedString(j.secret)
	if err != nil {
		return "", "", err
	}

	return accessToken, refreshToken, nil
}

func (j *JWT) ValidateAccessToken(tokenStr string) (*Claims, error) {
	return j.validateToken(tokenStr, "access")
}

func (j *JWT) ValidateRefreshToken(tokenStr string) (*Claims, error) {
	return j.validateToken(tokenStr, "refresh")
}

func (j *JWT) validateToken(tokenStr, expectedType string) (*Claims, error) {
	token, err := jwt.ParseWithClaims(tokenStr, &tokenClaims{}, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, ErrInvalidToken
		}
		return j.secret, nil
	})
	if err != nil {
		if errors.Is(err, jwt.ErrTokenExpired) {
			return nil, ErrExpiredToken
		}
		return nil, ErrInvalidToken
	}

	claims, ok := token.Claims.(*tokenClaims)
	if !ok || !token.Valid {
		return nil, ErrInvalidToken
	}
	if claims.Type != expectedType {
		return nil, ErrInvalidToken
	}

	return &Claims{
		UserID:   claims.UserID,
		Username: claims.Username,
		Role:     claims.Role,
	}, nil
}
```

- [ ] **Step 4: Install JWT dependency and run tests**

```bash
go get github.com/golang-jwt/jwt/v5
go test ./internal/auth/ -v
```

Expected: all 10 tests PASS (4 password + 6 JWT).

- [ ] **Step 5: Commit**

```bash
git add internal/auth/auth.go internal/auth/auth_test.go go.mod go.sum
git commit -m "feat: add JWT authentication with access and refresh tokens"
```

---

### Task 9: Auth Middleware

**Files:**
- Create: `internal/auth/middleware.go`
- Create: `internal/auth/middleware_test.go`

- [ ] **Step 1: Write middleware test**

Create `internal/auth/middleware_test.go`:

```go
package auth

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestMiddleware_ValidToken(t *testing.T) {
	j := NewJWT("test-secret-key-at-least-32-bytes!")
	token, _, _ := j.GenerateTokens("user-1", "alice", "admin")

	handler := RequireAuth(j)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		claims := GetClaims(r.Context())
		if claims == nil {
			t.Fatal("expected claims in context")
		}
		if claims.UserID != "user-1" {
			t.Fatalf("expected user-1, got %s", claims.UserID)
		}
		w.WriteHeader(http.StatusOK)
	}))

	req := httptest.NewRequest("GET", "/", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
}

func TestMiddleware_NoToken(t *testing.T) {
	j := NewJWT("test-secret-key-at-least-32-bytes!")
	handler := RequireAuth(j)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("should not reach handler")
	}))

	req := httptest.NewRequest("GET", "/", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
}

func TestMiddleware_InvalidToken(t *testing.T) {
	j := NewJWT("test-secret-key-at-least-32-bytes!")
	handler := RequireAuth(j)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("should not reach handler")
	}))

	req := httptest.NewRequest("GET", "/", nil)
	req.Header.Set("Authorization", "Bearer invalid-token")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
}

func TestRequireAdmin_AdminUser(t *testing.T) {
	j := NewJWT("test-secret-key-at-least-32-bytes!")
	token, _, _ := j.GenerateTokens("user-1", "alice", "admin")

	handler := RequireAuth(j)(RequireAdmin(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})))

	req := httptest.NewRequest("GET", "/", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
}

func TestRequireAdmin_NormalUser(t *testing.T) {
	j := NewJWT("test-secret-key-at-least-32-bytes!")
	token, _, _ := j.GenerateTokens("user-2", "bob", "user")

	handler := RequireAuth(j)(RequireAdmin(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("should not reach handler")
	})))

	req := httptest.NewRequest("GET", "/", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", rec.Code)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/auth/ -v -run TestMiddleware
```

Expected: FAIL — `RequireAuth` not defined.

- [ ] **Step 3: Implement middleware.go**

Create `internal/auth/middleware.go`:

```go
package auth

import (
	"context"
	"net/http"
	"strings"
)

type contextKey string

const claimsKey contextKey = "claims"

func RequireAuth(j *JWT) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			header := r.Header.Get("Authorization")
			if header == "" {
				http.Error(w, `{"error":"missing authorization header"}`, http.StatusUnauthorized)
				return
			}

			parts := strings.SplitN(header, " ", 2)
			if len(parts) != 2 || parts[0] != "Bearer" {
				http.Error(w, `{"error":"invalid authorization format"}`, http.StatusUnauthorized)
				return
			}

			claims, err := j.ValidateAccessToken(parts[1])
			if err != nil {
				http.Error(w, `{"error":"invalid or expired token"}`, http.StatusUnauthorized)
				return
			}

			ctx := context.WithValue(r.Context(), claimsKey, claims)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

func RequireAdmin(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		claims := GetClaims(r.Context())
		if claims == nil || claims.Role != "admin" {
			http.Error(w, `{"error":"admin access required"}`, http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func GetClaims(ctx context.Context) *Claims {
	claims, _ := ctx.Value(claimsKey).(*Claims)
	return claims
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
go test ./internal/auth/ -v
```

Expected: all 15 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/auth/middleware.go internal/auth/middleware_test.go
git commit -m "feat: add HTTP auth middleware with role-based access control"
```

---

**End of Chunk 2**

---

## Chunk 3: Versioning + Activity Log

### Task 10: Binary Delta Patches

**Files:**
- Create: `internal/versioning/delta.go`
- Create: `internal/versioning/delta_test.go`

- [ ] **Step 1: Write delta test**

Create `internal/versioning/delta_test.go`:

```go
package versioning

import (
	"bytes"
	"testing"
)

func TestCreatePatch(t *testing.T) {
	old := []byte("hello world, this is a test file with some content")
	new := []byte("hello world, this is a modified file with some content")

	patch, err := CreatePatch(old, new)
	if err != nil {
		t.Fatal(err)
	}
	if len(patch) == 0 {
		t.Fatal("expected non-empty patch")
	}
	// Patch should be smaller than the new file (delta compression)
	if len(patch) >= len(new) {
		t.Logf("patch size %d >= new size %d (may happen for small files)", len(patch), len(new))
	}
}

func TestApplyPatch(t *testing.T) {
	old := []byte("hello world, this is a test file with some content")
	new := []byte("hello world, this is a modified file with some content")

	patch, err := CreatePatch(old, new)
	if err != nil {
		t.Fatal(err)
	}

	result, err := ApplyPatch(old, patch)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(result, new) {
		t.Fatalf("expected '%s', got '%s'", new, result)
	}
}

func TestPatch_LargeFile(t *testing.T) {
	old := make([]byte, 100*1024) // 100KB
	for i := range old {
		old[i] = byte(i % 256)
	}
	new := make([]byte, len(old))
	copy(new, old)
	// Modify a small section
	copy(new[50000:50010], []byte("MODIFIED!!"))

	patch, err := CreatePatch(old, new)
	if err != nil {
		t.Fatal(err)
	}

	result, err := ApplyPatch(old, patch)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(result, new) {
		t.Fatal("round-trip failed for large file")
	}
}

func TestPatch_EmptyToContent(t *testing.T) {
	old := []byte{}
	new := []byte("brand new content")

	patch, _ := CreatePatch(old, new)
	result, err := ApplyPatch(old, patch)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(result, new) {
		t.Fatal("failed to create from empty")
	}
}

func TestPatch_IdenticalFiles(t *testing.T) {
	data := []byte("no changes at all")
	patch, _ := CreatePatch(data, data)
	result, err := ApplyPatch(data, patch)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(result, data) {
		t.Fatal("identical files should produce identity patch")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/versioning/ -v -run TestCreate
```

Expected: FAIL — `CreatePatch` not defined.

- [ ] **Step 3: Implement delta.go**

Create `internal/versioning/delta.go`:

```go
package versioning

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"io"
)

// CreatePatch generates a binary delta patch from old to new.
// Uses a simple block-based diff: divide old into blocks, find matching
// blocks in new, encode as copy/insert operations.
// Format: gzip([op][data]...)
//   op=0x01 len(4) data(len)  — insert literal bytes
//   op=0x02 offset(4) len(4)  — copy from old
const blockSize = 64

func CreatePatch(old, new []byte) ([]byte, error) {
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)

	// Build index of old blocks
	index := make(map[string]int) // block hash → offset
	for i := 0; i+blockSize <= len(old); i += blockSize {
		key := string(old[i : i+blockSize])
		if _, exists := index[key]; !exists {
			index[key] = i
		}
	}

	i := 0
	var pending []byte

	flushInsert := func() error {
		if len(pending) == 0 {
			return nil
		}
		if err := gz.Write([]byte{0x01}); err != nil {
			return err
		}
		if err := binary.Write(gz, binary.LittleEndian, uint32(len(pending))); err != nil {
			return err
		}
		if _, err := gz.Write(pending); err != nil {
			return err
		}
		pending = nil
		return nil
	}

	for i < len(new) {
		if i+blockSize <= len(new) {
			key := string(new[i : i+blockSize])
			if offset, ok := index[key]; ok {
				// Try to extend the match
				matchLen := blockSize
				for i+matchLen < len(new) && offset+matchLen < len(old) && new[i+matchLen] == old[offset+matchLen] {
					matchLen++
				}
				if err := flushInsert(); err != nil {
					return nil, err
				}
				if err := gz.Write([]byte{0x02}); err != nil {
					return nil, err
				}
				if err := binary.Write(gz, binary.LittleEndian, uint32(offset)); err != nil {
					return nil, err
				}
				if err := binary.Write(gz, binary.LittleEndian, uint32(matchLen)); err != nil {
					return nil, err
				}
				i += matchLen
				continue
			}
		}
		pending = append(pending, new[i])
		i++
	}
	if err := flushInsert(); err != nil {
		return nil, err
	}

	if err := gz.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func ApplyPatch(old, patch []byte) ([]byte, error) {
	gz, err := gzip.NewReader(bytes.NewReader(patch))
	if err != nil {
		return nil, err
	}
	defer gz.Close()

	var result bytes.Buffer

	for {
		var op [1]byte
		_, err := io.ReadFull(gz, op[:])
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}

		switch op[0] {
		case 0x01: // Insert
			var length uint32
			if err := binary.Read(gz, binary.LittleEndian, &length); err != nil {
				return nil, err
			}
			data := make([]byte, length)
			if _, err := io.ReadFull(gz, data); err != nil {
				return nil, err
			}
			result.Write(data)

		case 0x02: // Copy from old
			var offset, length uint32
			if err := binary.Read(gz, binary.LittleEndian, &offset); err != nil {
				return nil, err
			}
			if err := binary.Read(gz, binary.LittleEndian, &length); err != nil {
				return nil, err
			}
			result.Write(old[offset : offset+length])
		}
	}

	return result.Bytes(), nil
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
go test ./internal/versioning/ -v -run TestCreate
go test ./internal/versioning/ -v -run TestApply
go test ./internal/versioning/ -v -run TestPatch
```

Expected: all 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/versioning/delta.go internal/versioning/delta_test.go
git commit -m "feat: add binary delta patch creation and application"
```

---

### Task 11: Version Management

**Files:**
- Create: `internal/metadata/versions.go`
- Create: `internal/metadata/versions_test.go`

- [ ] **Step 1: Write version metadata test**

Create `internal/metadata/versions_test.go`:

```go
package metadata

import (
	"testing"
)

func TestVersions_Create(t *testing.T) {
	db := testDB(t)
	u := seedUser(t, db)
	f, _ := db.CreateFile("", u.ID, "doc.txt", false, 100, "hash1", "text/plain")

	v, err := db.CreateVersion(f.ID, 1, "hash1", "", 100, u.ID)
	if err != nil {
		t.Fatal(err)
	}
	if v.VersionNum != 1 {
		t.Fatalf("expected version 1, got %d", v.VersionNum)
	}
}

func TestVersions_List(t *testing.T) {
	db := testDB(t)
	u := seedUser(t, db)
	f, _ := db.CreateFile("", u.ID, "doc.txt", false, 100, "hash3", "text/plain")

	db.CreateVersion(f.ID, 1, "hash1", "", 100, u.ID)
	db.CreateVersion(f.ID, 2, "hash2", "patch1", 110, u.ID)
	db.CreateVersion(f.ID, 3, "hash3", "patch2", 120, u.ID)

	versions, err := db.ListVersions(f.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(versions) != 3 {
		t.Fatalf("expected 3 versions, got %d", len(versions))
	}
	// Should be ordered newest first
	if versions[0].VersionNum != 3 {
		t.Fatalf("expected newest first, got version %d", versions[0].VersionNum)
	}
}

func TestVersions_GetLatest(t *testing.T) {
	db := testDB(t)
	u := seedUser(t, db)
	f, _ := db.CreateFile("", u.ID, "doc.txt", false, 100, "hash2", "text/plain")

	db.CreateVersion(f.ID, 1, "hash1", "", 100, u.ID)
	db.CreateVersion(f.ID, 2, "hash2", "patch1", 110, u.ID)

	v, err := db.GetLatestVersion(f.ID)
	if err != nil {
		t.Fatal(err)
	}
	if v.VersionNum != 2 {
		t.Fatalf("expected version 2, got %d", v.VersionNum)
	}
}

func TestVersions_Count(t *testing.T) {
	db := testDB(t)
	u := seedUser(t, db)
	f, _ := db.CreateFile("", u.ID, "doc.txt", false, 100, "hash1", "text/plain")

	db.CreateVersion(f.ID, 1, "hash1", "", 100, u.ID)
	db.CreateVersion(f.ID, 2, "hash2", "p1", 110, u.ID)

	count, err := db.CountVersions(f.ID)
	if err != nil {
		t.Fatal(err)
	}
	if count != 2 {
		t.Fatalf("expected 2, got %d", count)
	}
}

func TestVersions_DeleteOldest(t *testing.T) {
	db := testDB(t)
	u := seedUser(t, db)
	f, _ := db.CreateFile("", u.ID, "doc.txt", false, 100, "hash1", "text/plain")

	db.CreateVersion(f.ID, 1, "hash1", "", 100, u.ID)
	db.CreateVersion(f.ID, 2, "hash2", "p1", 110, u.ID)
	db.CreateVersion(f.ID, 3, "hash3", "p2", 120, u.ID)

	err := db.DeleteOldestVersion(f.ID)
	if err != nil {
		t.Fatal(err)
	}

	versions, _ := db.ListVersions(f.ID)
	if len(versions) != 2 {
		t.Fatalf("expected 2 versions after delete, got %d", len(versions))
	}
	if versions[1].VersionNum != 2 {
		t.Fatal("oldest remaining should be version 2")
	}
}

func TestVersions_DeleteByID(t *testing.T) {
	db := testDB(t)
	u := seedUser(t, db)
	f, _ := db.CreateFile("", u.ID, "doc.txt", false, 100, "hash1", "text/plain")

	v, _ := db.CreateVersion(f.ID, 1, "hash1", "", 100, u.ID)
	err := db.DeleteVersion(v.ID)
	if err != nil {
		t.Fatal(err)
	}

	count, _ := db.CountVersions(f.ID)
	if count != 0 {
		t.Fatalf("expected 0 versions, got %d", count)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/metadata/ -v -run TestVersions
```

Expected: FAIL — `CreateVersion` not defined.

- [ ] **Step 3: Implement versions.go**

Create `internal/metadata/versions.go`:

```go
package metadata

import (
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

type Version struct {
	ID          string
	FileID      string
	VersionNum  int
	ContentHash string
	PatchHash   string
	Size        int64
	CreatedBy   string
	CreatedAt   time.Time
}

func (db *DB) CreateVersion(fileID string, versionNum int, contentHash, patchHash string, size int64, createdBy string) (*Version, error) {
	v := &Version{
		ID:          uuid.New().String(),
		FileID:      fileID,
		VersionNum:  versionNum,
		ContentHash: contentHash,
		PatchHash:   patchHash,
		Size:        size,
		CreatedBy:   createdBy,
		CreatedAt:   time.Now().UTC(),
	}
	_, err := db.conn.Exec(
		`INSERT INTO versions (id, file_id, version_num, content_hash, patch_hash, size, created_by, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		v.ID, v.FileID, v.VersionNum, v.ContentHash, nullString(v.PatchHash),
		v.Size, v.CreatedBy, v.CreatedAt,
	)
	if err != nil {
		return nil, fmt.Errorf("create version: %w", err)
	}
	return v, nil
}

func (db *DB) ListVersions(fileID string) ([]Version, error) {
	rows, err := db.conn.Query(
		`SELECT id, file_id, version_num, content_hash, patch_hash, size, created_by, created_at
		 FROM versions WHERE file_id = ? ORDER BY version_num DESC`, fileID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var versions []Version
	for rows.Next() {
		v, err := scanVersionRow(rows)
		if err != nil {
			return nil, err
		}
		versions = append(versions, *v)
	}
	return versions, rows.Err()
}

func (db *DB) GetLatestVersion(fileID string) (*Version, error) {
	row := db.conn.QueryRow(
		`SELECT id, file_id, version_num, content_hash, patch_hash, size, created_by, created_at
		 FROM versions WHERE file_id = ? ORDER BY version_num DESC LIMIT 1`, fileID,
	)
	return scanVersion(row)
}

func (db *DB) GetVersionByNum(fileID string, num int) (*Version, error) {
	row := db.conn.QueryRow(
		`SELECT id, file_id, version_num, content_hash, patch_hash, size, created_by, created_at
		 FROM versions WHERE file_id = ? AND version_num = ?`, fileID, num,
	)
	return scanVersion(row)
}

func (db *DB) CountVersions(fileID string) (int, error) {
	var count int
	err := db.conn.QueryRow(`SELECT COUNT(*) FROM versions WHERE file_id = ?`, fileID).Scan(&count)
	return count, err
}

func (db *DB) DeleteOldestVersion(fileID string) error {
	_, err := db.conn.Exec(
		`DELETE FROM versions WHERE id = (
			SELECT id FROM versions WHERE file_id = ? ORDER BY version_num ASC LIMIT 1
		)`, fileID,
	)
	return err
}

func (db *DB) DeleteVersion(id string) error {
	_, err := db.conn.Exec(`DELETE FROM versions WHERE id = ?`, id)
	return err
}

func (db *DB) DeleteVersionsOlderThan(fileID string, before time.Time) (int64, error) {
	result, err := db.conn.Exec(
		`DELETE FROM versions WHERE file_id = ? AND created_at < ?`,
		fileID, before,
	)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

func scanVersion(row *sql.Row) (*Version, error) {
	var v Version
	var patchHash sql.NullString
	err := row.Scan(&v.ID, &v.FileID, &v.VersionNum, &v.ContentHash,
		&patchHash, &v.Size, &v.CreatedBy, &v.CreatedAt)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	v.PatchHash = patchHash.String
	return &v, nil
}

func scanVersionRow(rows *sql.Rows) (*Version, error) {
	var v Version
	var patchHash sql.NullString
	err := rows.Scan(&v.ID, &v.FileID, &v.VersionNum, &v.ContentHash,
		&patchHash, &v.Size, &v.CreatedBy, &v.CreatedAt)
	if err != nil {
		return nil, err
	}
	v.PatchHash = patchHash.String
	return &v, nil
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
go test ./internal/metadata/ -v -run TestVersions
```

Expected: all 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/metadata/versions.go internal/metadata/versions_test.go
git commit -m "feat: add version metadata CRUD operations"
```

---

### Task 12: Version Rotation Algorithms

**Files:**
- Create: `internal/versioning/rotation.go`
- Create: `internal/versioning/rotation_test.go`

- [ ] **Step 1: Write rotation test**

Create `internal/versioning/rotation_test.go`:

```go
package versioning

import (
	"fmt"
	"testing"
	"time"
)

func TestFIFO_UnderLimit(t *testing.T) {
	versions := makeVersions(5, time.Now(), time.Hour)
	toDelete := FIFO(versions, 10)
	if len(toDelete) != 0 {
		t.Fatalf("expected 0 deletions, got %d", len(toDelete))
	}
}

func TestFIFO_AtLimit(t *testing.T) {
	versions := makeVersions(10, time.Now(), time.Hour)
	toDelete := FIFO(versions, 10)
	if len(toDelete) != 0 {
		t.Fatalf("expected 0 deletions at limit, got %d", len(toDelete))
	}
}

func TestFIFO_OverLimit(t *testing.T) {
	versions := makeVersions(35, time.Now(), time.Hour)
	toDelete := FIFO(versions, 32)
	if len(toDelete) != 3 {
		t.Fatalf("expected 3 deletions, got %d", len(toDelete))
	}
	// Should delete the oldest ones
	if toDelete[0].Num != 1 {
		t.Fatalf("expected oldest (1) first, got %d", toDelete[0].Num)
	}
}

func TestIntelliversioning_ClustersRemoved(t *testing.T) {
	now := time.Now()
	// Create 35 versions: 30 clustered in last hour + 5 spread over past week
	var versions []VersionInfo
	for i := 1; i <= 5; i++ {
		versions = append(versions, VersionInfo{
			ID:        idStr(i),
			Num:       i,
			CreatedAt: now.Add(-time.Duration(7-i) * 24 * time.Hour),
		})
	}
	for i := 6; i <= 35; i++ {
		versions = append(versions, VersionInfo{
			ID:        idStr(i),
			Num:       i,
			CreatedAt: now.Add(-time.Duration(35-i) * 2 * time.Minute),
		})
	}

	toDelete := Intelliversioning(versions, 32)
	if len(toDelete) != 3 {
		t.Fatalf("expected 3 deletions, got %d", len(toDelete))
	}

	// The deleted versions should be from the cluster, not the spread-out ones
	for _, d := range toDelete {
		if d.Num <= 5 {
			t.Fatalf("should not delete spread-out version %d", d.Num)
		}
	}
}

// Helpers

func makeVersions(n int, startTime time.Time, interval time.Duration) []VersionInfo {
	var versions []VersionInfo
	for i := 1; i <= n; i++ {
		versions = append(versions, VersionInfo{
			ID:        fmt.Sprintf("v-%d", i),
			Num:       i,
			CreatedAt: startTime.Add(-time.Duration(n-i) * interval),
		})
	}
	return versions
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/versioning/ -v -run TestFIFO
```

Expected: FAIL — `FIFO` not defined.

- [ ] **Step 3: Implement rotation.go**

Create `internal/versioning/rotation.go`:

```go
package versioning

import (
	"fmt"
	"sort"
	"time"
)

type VersionInfo struct {
	ID        string
	Num       int
	CreatedAt time.Time
}

// FIFO removes the oldest versions when count exceeds maxVersions.
func FIFO(versions []VersionInfo, maxVersions int) []VersionInfo {
	if len(versions) <= maxVersions {
		return nil
	}

	// Sort oldest first
	sorted := make([]VersionInfo, len(versions))
	copy(sorted, versions)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i].CreatedAt.Before(sorted[j].CreatedAt)
	})

	excess := len(sorted) - maxVersions
	return sorted[:excess]
}

// Intelliversioning removes clustered versions, keeping those that are more
// spread out in time. When the limit is exceeded, it identifies which versions
// are closest together and removes those first.
func Intelliversioning(versions []VersionInfo, maxVersions int) []VersionInfo {
	if len(versions) <= maxVersions {
		return nil
	}

	excess := len(versions) - maxVersions

	// Sort by time
	sorted := make([]VersionInfo, len(versions))
	copy(sorted, versions)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i].CreatedAt.Before(sorted[j].CreatedAt)
	})

	// Never delete the first or last version
	var toDelete []VersionInfo

	for len(toDelete) < excess {
		// Find the pair of adjacent versions with smallest time gap
		minGap := time.Duration(1<<63 - 1)
		minIdx := -1

		for i := 1; i < len(sorted)-1; i++ {
			// Skip already marked for deletion
			if isMarked(sorted[i].ID, toDelete) {
				continue
			}
			gap := sorted[i+1].CreatedAt.Sub(sorted[i].CreatedAt)
			// Also consider gap to previous
			prevGap := sorted[i].CreatedAt.Sub(sorted[i-1].CreatedAt)
			combinedGap := gap + prevGap

			if combinedGap < minGap {
				minGap = combinedGap
				minIdx = i
			}
		}

		if minIdx < 0 {
			break
		}
		toDelete = append(toDelete, sorted[minIdx])

		// Remove from sorted to recalculate gaps
		sorted = append(sorted[:minIdx], sorted[minIdx+1:]...)
	}

	return toDelete
}

func isMarked(id string, list []VersionInfo) bool {
	for _, v := range list {
		if v.ID == id {
			return true
		}
	}
	return false
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
go test ./internal/versioning/ -v
```

Expected: all tests PASS (5 delta + 4 rotation).

- [ ] **Step 5: Commit**

```bash
git add internal/versioning/rotation.go internal/versioning/rotation_test.go
git commit -m "feat: add FIFO and Intelliversioning rotation algorithms"
```

---

### Task 13: Activity Log

**Files:**
- Create: `internal/metadata/activity.go`
- Create: `internal/metadata/activity_test.go`

- [ ] **Step 1: Write activity log test**

Create `internal/metadata/activity_test.go`:

```go
package metadata

import (
	"testing"
	"time"
)

func TestActivity_Log(t *testing.T) {
	db := testDB(t)
	u := seedUser(t, db)

	err := db.LogActivity(u.ID, "upload", "file", "file-123", `{"name":"doc.txt"}`, "192.168.1.1")
	if err != nil {
		t.Fatal(err)
	}
}

func TestActivity_Query(t *testing.T) {
	db := testDB(t)
	u := seedUser(t, db)

	db.LogActivity(u.ID, "upload", "file", "f1", "", "")
	db.LogActivity(u.ID, "download", "file", "f2", "", "")
	db.LogActivity(u.ID, "delete", "file", "f3", "", "")

	entries, err := db.QueryActivity(ActivityQuery{Limit: 10})
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 3 {
		t.Fatalf("expected 3 entries, got %d", len(entries))
	}
	// Newest first
	if entries[0].Action != "delete" {
		t.Fatalf("expected newest first")
	}
}

func TestActivity_FilterByUser(t *testing.T) {
	db := testDB(t)
	u1, _ := db.CreateUser("u1", "u1@x.com", "pw", "user")
	u2, _ := db.CreateUser("u2", "u2@x.com", "pw", "user")

	db.LogActivity(u1.ID, "upload", "file", "f1", "", "")
	db.LogActivity(u2.ID, "upload", "file", "f2", "", "")
	db.LogActivity(u1.ID, "download", "file", "f1", "", "")

	entries, _ := db.QueryActivity(ActivityQuery{UserID: u1.ID, Limit: 10})
	if len(entries) != 2 {
		t.Fatalf("expected 2 entries for u1, got %d", len(entries))
	}
}

func TestActivity_FilterByAction(t *testing.T) {
	db := testDB(t)
	u := seedUser(t, db)

	db.LogActivity(u.ID, "upload", "file", "f1", "", "")
	db.LogActivity(u.ID, "download", "file", "f2", "", "")
	db.LogActivity(u.ID, "upload", "file", "f3", "", "")

	entries, _ := db.QueryActivity(ActivityQuery{Action: "upload", Limit: 10})
	if len(entries) != 2 {
		t.Fatalf("expected 2 uploads, got %d", len(entries))
	}
}

func TestActivity_FilterByDateRange(t *testing.T) {
	db := testDB(t)
	u := seedUser(t, db)

	db.LogActivity(u.ID, "upload", "file", "f1", "", "")

	future := time.Now().Add(1 * time.Hour)
	entries, _ := db.QueryActivity(ActivityQuery{After: &future, Limit: 10})
	if len(entries) != 0 {
		t.Fatalf("expected 0 entries in future, got %d", len(entries))
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/metadata/ -v -run TestActivity
```

Expected: FAIL — `LogActivity` not defined.

- [ ] **Step 3: Implement activity.go**

Create `internal/metadata/activity.go`:

```go
package metadata

import (
	"database/sql"
	"fmt"
	"time"

	"github.com/google/uuid"
)

type ActivityEntry struct {
	ID         string
	UserID     string
	Action     string
	Resource   string
	ResourceID string
	Details    string
	IPAddress  string
	CreatedAt  time.Time
}

type ActivityQuery struct {
	UserID string
	Action string
	After  *time.Time
	Before *time.Time
	Limit  int
	Offset int
}

func (db *DB) LogActivity(userID, action, resource, resourceID, details, ipAddress string) error {
	_, err := db.conn.Exec(
		`INSERT INTO activity_log (id, user_id, action, resource, resource_id, details, ip_address, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		uuid.New().String(), userID, action, resource,
		nullString(resourceID), nullString(details), nullString(ipAddress),
		time.Now().UTC(),
	)
	return err
}

func (db *DB) QueryActivity(q ActivityQuery) ([]ActivityEntry, error) {
	query := `SELECT id, user_id, action, resource, resource_id, details, ip_address, created_at
		FROM activity_log WHERE 1=1`
	var args []interface{}

	if q.UserID != "" {
		query += " AND user_id = ?"
		args = append(args, q.UserID)
	}
	if q.Action != "" {
		query += " AND action = ?"
		args = append(args, q.Action)
	}
	if q.After != nil {
		query += " AND created_at > ?"
		args = append(args, *q.After)
	}
	if q.Before != nil {
		query += " AND created_at < ?"
		args = append(args, *q.Before)
	}

	query += " ORDER BY created_at DESC"

	if q.Limit > 0 {
		query += fmt.Sprintf(" LIMIT %d", q.Limit)
	}
	if q.Offset > 0 {
		query += fmt.Sprintf(" OFFSET %d", q.Offset)
	}

	rows, err := db.conn.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var entries []ActivityEntry
	for rows.Next() {
		var e ActivityEntry
		var resourceID, details, ipAddress, userID sql.NullString
		err := rows.Scan(&e.ID, &userID, &e.Action, &e.Resource,
			&resourceID, &details, &ipAddress, &e.CreatedAt)
		if err != nil {
			return nil, err
		}
		e.UserID = userID.String
		e.ResourceID = resourceID.String
		e.Details = details.String
		e.IPAddress = ipAddress.String
		entries = append(entries, e)
	}
	return entries, rows.Err()
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
go test ./internal/metadata/ -v -run TestActivity
```

Expected: all 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/metadata/activity.go internal/metadata/activity_test.go
git commit -m "feat: add activity log with query filtering"
```

---

**End of Chunk 3**

---

## Chunk 4: Share Links + REST API Foundation

### Task 14: Share Link Operations

**Files:**
- Create: `internal/metadata/shares.go`
- Create: `internal/metadata/shares_test.go`

- [ ] **Step 1: Write shares test**

Create `internal/metadata/shares_test.go`:

```go
package metadata

import (
	"testing"
	"time"
)

func TestShares_Create(t *testing.T) {
	db := testDB(t)
	u := seedUser(t, db)
	f, _ := db.CreateFile("", u.ID, "share.txt", false, 100, "h", "text/plain")

	link, err := db.CreateShareLink(f.ID, u.ID, "", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	if link.Token == "" {
		t.Fatal("expected non-empty token")
	}
	if link.FileID != f.ID {
		t.Fatal("wrong file ID")
	}
}

func TestShares_WithPassword(t *testing.T) {
	db := testDB(t)
	u := seedUser(t, db)
	f, _ := db.CreateFile("", u.ID, "secret.txt", false, 100, "h", "text/plain")

	link, _ := db.CreateShareLink(f.ID, u.ID, "hashed_pw", nil, 0)
	if link.PasswordHash == "" {
		t.Fatal("expected password hash")
	}
}

func TestShares_WithExpiration(t *testing.T) {
	db := testDB(t)
	u := seedUser(t, db)
	f, _ := db.CreateFile("", u.ID, "temp.txt", false, 100, "h", "text/plain")

	expires := time.Now().Add(24 * time.Hour)
	link, _ := db.CreateShareLink(f.ID, u.ID, "", &expires, 0)
	if link.ExpiresAt == nil {
		t.Fatal("expected expiration")
	}
}

func TestShares_GetByToken(t *testing.T) {
	db := testDB(t)
	u := seedUser(t, db)
	f, _ := db.CreateFile("", u.ID, "get.txt", false, 100, "h", "text/plain")

	created, _ := db.CreateShareLink(f.ID, u.ID, "", nil, 0)
	got, err := db.GetShareLinkByToken(created.Token)
	if err != nil {
		t.Fatal(err)
	}
	if got.ID != created.ID {
		t.Fatal("wrong share link")
	}
}

func TestShares_IncrementDownload(t *testing.T) {
	db := testDB(t)
	u := seedUser(t, db)
	f, _ := db.CreateFile("", u.ID, "dl.txt", false, 100, "h", "text/plain")

	link, _ := db.CreateShareLink(f.ID, u.ID, "", nil, 5)
	db.IncrementShareDownload(link.ID)
	db.IncrementShareDownload(link.ID)

	got, _ := db.GetShareLinkByToken(link.Token)
	if got.DownloadCount != 2 {
		t.Fatalf("expected 2 downloads, got %d", got.DownloadCount)
	}
}

func TestShares_Delete(t *testing.T) {
	db := testDB(t)
	u := seedUser(t, db)
	f, _ := db.CreateFile("", u.ID, "del.txt", false, 100, "h", "text/plain")

	link, _ := db.CreateShareLink(f.ID, u.ID, "", nil, 0)
	db.DeleteShareLink(link.ID)

	_, err := db.GetShareLinkByToken(link.Token)
	if err == nil {
		t.Fatal("expected error after deletion")
	}
}

func TestShares_ListByFile(t *testing.T) {
	db := testDB(t)
	u := seedUser(t, db)
	f, _ := db.CreateFile("", u.ID, "multi.txt", false, 100, "h", "text/plain")

	db.CreateShareLink(f.ID, u.ID, "", nil, 0)
	db.CreateShareLink(f.ID, u.ID, "pw", nil, 0)

	links, err := db.ListShareLinks(f.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(links) != 2 {
		t.Fatalf("expected 2 links, got %d", len(links))
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/metadata/ -v -run TestShares
```

Expected: FAIL — `CreateShareLink` not defined.

- [ ] **Step 3: Implement shares.go**

Create `internal/metadata/shares.go`:

```go
package metadata

import (
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

type ShareLink struct {
	ID            string
	FileID        string
	Token         string
	PasswordHash  string
	ExpiresAt     *time.Time
	MaxDownloads  int
	DownloadCount int
	CreatedBy     string
	CreatedAt     time.Time
}

func (db *DB) CreateShareLink(fileID, createdBy, passwordHash string, expiresAt *time.Time, maxDownloads int) (*ShareLink, error) {
	token, err := generateToken(16)
	if err != nil {
		return nil, err
	}

	link := &ShareLink{
		ID:           uuid.New().String(),
		FileID:       fileID,
		Token:        token,
		PasswordHash: passwordHash,
		ExpiresAt:    expiresAt,
		MaxDownloads: maxDownloads,
		CreatedBy:    createdBy,
		CreatedAt:    time.Now().UTC(),
	}

	_, err = db.conn.Exec(
		`INSERT INTO share_links (id, file_id, token, password_hash, expires_at, max_downloads, download_count, created_by, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)`,
		link.ID, link.FileID, link.Token, nullString(link.PasswordHash),
		nullTimePtr(link.ExpiresAt), link.MaxDownloads, link.CreatedBy, link.CreatedAt,
	)
	if err != nil {
		return nil, fmt.Errorf("create share link: %w", err)
	}
	return link, nil
}

func (db *DB) GetShareLinkByToken(token string) (*ShareLink, error) {
	row := db.conn.QueryRow(
		`SELECT id, file_id, token, password_hash, expires_at, max_downloads, download_count, created_by, created_at
		 FROM share_links WHERE token = ?`, token,
	)
	return scanShareLink(row)
}

func (db *DB) ListShareLinks(fileID string) ([]ShareLink, error) {
	rows, err := db.conn.Query(
		`SELECT id, file_id, token, password_hash, expires_at, max_downloads, download_count, created_by, created_at
		 FROM share_links WHERE file_id = ? ORDER BY created_at DESC`, fileID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var links []ShareLink
	for rows.Next() {
		var l ShareLink
		var pw sql.NullString
		var exp sql.NullTime
		err := rows.Scan(&l.ID, &l.FileID, &l.Token, &pw, &exp,
			&l.MaxDownloads, &l.DownloadCount, &l.CreatedBy, &l.CreatedAt)
		if err != nil {
			return nil, err
		}
		l.PasswordHash = pw.String
		if exp.Valid {
			l.ExpiresAt = &exp.Time
		}
		links = append(links, l)
	}
	return links, rows.Err()
}

func (db *DB) IncrementShareDownload(id string) error {
	_, err := db.conn.Exec(
		`UPDATE share_links SET download_count = download_count + 1 WHERE id = ?`, id,
	)
	return err
}

func (db *DB) DeleteShareLink(id string) error {
	_, err := db.conn.Exec(`DELETE FROM share_links WHERE id = ?`, id)
	return err
}

func scanShareLink(row *sql.Row) (*ShareLink, error) {
	var l ShareLink
	var pw sql.NullString
	var exp sql.NullTime
	err := row.Scan(&l.ID, &l.FileID, &l.Token, &pw, &exp,
		&l.MaxDownloads, &l.DownloadCount, &l.CreatedBy, &l.CreatedAt)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrNotFound
		}
		return nil, err
	}
	l.PasswordHash = pw.String
	if exp.Valid {
		l.ExpiresAt = &exp.Time
	}
	return &l, nil
}

func generateToken(length int) (string, error) {
	b := make([]byte, length)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.URLEncoding.WithPadding(base64.NoPadding).EncodeToString(b), nil
}

func nullTimePtr(t *time.Time) interface{} {
	if t == nil {
		return nil
	}
	return *t
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
go test ./internal/metadata/ -v -run TestShares
```

Expected: all 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/metadata/shares.go internal/metadata/shares_test.go
git commit -m "feat: add share link operations with tokens and download limits"
```

---

### Task 15: REST API Server Setup

**Files:**
- Create: `internal/api/rest/server.go`
- Create: `internal/api/rest/middleware.go`
- Create: `internal/api/rest/server_test.go`

- [ ] **Step 1: Write server setup test**

Create `internal/api/rest/server_test.go`:

```go
package rest

import (
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
	"github.com/NielHeesakkers/SyncVault/internal/metadata"
	"github.com/NielHeesakkers/SyncVault/internal/storage"
)

type testEnv struct {
	server *Server
	db     *metadata.DB
	store  *storage.Store
	jwt    *auth.JWT
}

func setupTest(t *testing.T) *testEnv {
	t.Helper()
	dir := t.TempDir()

	db, err := metadata.Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })

	store, err := storage.NewStore(filepath.Join(dir, "chunks"), 1024)
	if err != nil {
		t.Fatal(err)
	}

	j := auth.NewJWT("test-secret-key-at-least-32-bytes!")
	srv := NewServer(db, store, j)

	return &testEnv{server: srv, db: db, store: store, jwt: j}
}

func TestServer_Health(t *testing.T) {
	env := setupTest(t)
	req := httptest.NewRequest("GET", "/api/health", nil)
	rec := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
}

func TestServer_ProtectedEndpoint_NoAuth(t *testing.T) {
	env := setupTest(t)
	req := httptest.NewRequest("GET", "/api/files", nil)
	rec := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/api/rest/ -v -run TestServer
```

Expected: FAIL — `NewServer` not defined.

- [ ] **Step 3: Implement server.go and middleware.go**

Create `internal/api/rest/middleware.go`:

```go
package rest

import (
	"log"
	"net/http"
	"time"
)

func CORSMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")

		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusOK)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func LoggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		wrapped := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(wrapped, r)
		log.Printf("%s %s %d %s", r.Method, r.URL.Path, wrapped.status, time.Since(start))
	})
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(status int) {
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}
```

Create `internal/api/rest/server.go`:

```go
package rest

import (
	"encoding/json"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/NielHeesakkers/SyncVault/internal/auth"
	"github.com/NielHeesakkers/SyncVault/internal/metadata"
	"github.com/NielHeesakkers/SyncVault/internal/storage"
)

type Server struct {
	db    *metadata.DB
	store *storage.Store
	jwt   *auth.JWT
	router chi.Router
}

func NewServer(db *metadata.DB, store *storage.Store, jwt *auth.JWT) *Server {
	s := &Server{
		db:    db,
		store: store,
		jwt:   jwt,
	}
	s.router = s.setupRoutes()
	return s
}

func (s *Server) Router() http.Handler {
	return s.router
}

func (s *Server) setupRoutes() chi.Router {
	r := chi.NewRouter()
	r.Use(CORSMiddleware)
	r.Use(LoggingMiddleware)

	// Public routes
	r.Get("/api/health", s.handleHealth)

	// Protected routes
	r.Group(func(r chi.Router) {
		r.Use(auth.RequireAuth(s.jwt))

		r.Get("/api/files", s.handleNotImplemented)
		r.Get("/api/me", s.handleMe)
	})

	return r
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	writeJSON(w, http.StatusOK, map[string]string{
		"user_id":  claims.UserID,
		"username": claims.Username,
		"role":     claims.Role,
	})
}

func (s *Server) handleNotImplemented(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusNotImplemented, map[string]string{"error": "not implemented"})
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func readJSON(r *http.Request, v interface{}) error {
	defer r.Body.Close()
	return json.NewDecoder(r.Body).Decode(v)
}
```

- [ ] **Step 4: Install chi and run tests**

```bash
go get github.com/go-chi/chi/v5
go test ./internal/api/rest/ -v
```

Expected: both tests PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/api/rest/ go.mod go.sum
git commit -m "feat: add REST API server with chi router, health check, and auth middleware"
```

---

**End of Chunk 4**

---

## Chunk 5: REST API Endpoints

### Task 16: Auth Endpoints (Login, Register, Refresh)

**Files:**
- Create: `internal/api/rest/auth_handlers.go`
- Create: `internal/api/rest/auth_handlers_test.go`

- [ ] **Step 1: Write auth endpoint tests**

Create `internal/api/rest/auth_handlers_test.go`:

```go
package rest

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	iauth "github.com/NielHeesakkers/SyncVault/internal/auth"
)

func TestAuth_Register(t *testing.T) {
	env := setupTest(t)
	// First create an admin user to authorize registration
	pw, _ := iauth.HashPassword("adminpass")
	admin, _ := env.db.CreateUser("admin", "admin@test.com", pw, "admin")
	token, _, _ := env.jwt.GenerateTokens(admin.ID, "admin", "admin")

	body := `{"username":"alice","email":"alice@test.com","password":"secret123"}`
	req := httptest.NewRequest("POST", "/api/users", bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}

	var resp map[string]interface{}
	json.Unmarshal(rec.Body.Bytes(), &resp)
	if resp["username"] != "alice" {
		t.Fatalf("expected alice, got %v", resp["username"])
	}
}

func TestAuth_Login(t *testing.T) {
	env := setupTest(t)
	pw, _ := iauth.HashPassword("mypassword")
	env.db.CreateUser("bob", "bob@test.com", pw, "user")

	body := `{"username":"bob","password":"mypassword"}`
	req := httptest.NewRequest("POST", "/api/auth/login", bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var resp map[string]interface{}
	json.Unmarshal(rec.Body.Bytes(), &resp)
	if resp["access_token"] == nil {
		t.Fatal("expected access_token in response")
	}
	if resp["refresh_token"] == nil {
		t.Fatal("expected refresh_token in response")
	}
}

func TestAuth_LoginWrongPassword(t *testing.T) {
	env := setupTest(t)
	pw, _ := iauth.HashPassword("correct")
	env.db.CreateUser("charlie", "c@test.com", pw, "user")

	body := `{"username":"charlie","password":"wrong"}`
	req := httptest.NewRequest("POST", "/api/auth/login", bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
}

func TestAuth_Refresh(t *testing.T) {
	env := setupTest(t)
	pw, _ := iauth.HashPassword("pass")
	u, _ := env.db.CreateUser("dave", "d@test.com", pw, "user")
	_, refresh, _ := env.jwt.GenerateTokens(u.ID, "dave", "user")

	body, _ := json.Marshal(map[string]string{"refresh_token": refresh})
	req := httptest.NewRequest("POST", "/api/auth/refresh", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/api/rest/ -v -run TestAuth
```

Expected: FAIL — routes not registered.

- [ ] **Step 3: Implement auth_handlers.go and register routes**

Create `internal/api/rest/auth_handlers.go`:

```go
package rest

import (
	"net/http"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
)

type loginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type registerRequest struct {
	Username string `json:"username"`
	Email    string `json:"email"`
	Password string `json:"password"`
	Role     string `json:"role"`
}

type refreshRequest struct {
	RefreshToken string `json:"refresh_token"`
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	var req loginRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	user, err := s.db.GetUserByUsername(req.Username)
	if err != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid credentials"})
		return
	}

	if !auth.CheckPassword(req.Password, user.Password) {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid credentials"})
		return
	}

	access, refresh, err := s.jwt.GenerateTokens(user.ID, user.Username, user.Role)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to generate tokens"})
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"access_token":  access,
		"refresh_token": refresh,
		"user": map[string]interface{}{
			"id":       user.ID,
			"username": user.Username,
			"email":    user.Email,
			"role":     user.Role,
		},
	})
}

func (s *Server) handleCreateUser(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	if claims.Role != "admin" {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "admin access required"})
		return
	}

	var req registerRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	if req.Role == "" {
		req.Role = "user"
	}

	hashedPw, err := auth.HashPassword(req.Password)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to hash password"})
		return
	}

	user, err := s.db.CreateUser(req.Username, req.Email, hashedPw, req.Role)
	if err != nil {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "username or email already exists"})
		return
	}

	writeJSON(w, http.StatusCreated, map[string]interface{}{
		"id":       user.ID,
		"username": user.Username,
		"email":    user.Email,
		"role":     user.Role,
	})
}

func (s *Server) handleRefresh(w http.ResponseWriter, r *http.Request) {
	var req refreshRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	claims, err := s.jwt.ValidateRefreshToken(req.RefreshToken)
	if err != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid refresh token"})
		return
	}

	access, refresh, err := s.jwt.GenerateTokens(claims.UserID, claims.Username, claims.Role)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to generate tokens"})
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"access_token":  access,
		"refresh_token": refresh,
	})
}
```

Update `internal/api/rest/server.go` — add routes in `setupRoutes()`:

Replace the route setup section with:

```go
func (s *Server) setupRoutes() chi.Router {
	r := chi.NewRouter()
	r.Use(CORSMiddleware)
	r.Use(LoggingMiddleware)

	// Public routes
	r.Get("/api/health", s.handleHealth)
	r.Post("/api/auth/login", s.handleLogin)
	r.Post("/api/auth/refresh", s.handleRefresh)

	// Protected routes
	r.Group(func(r chi.Router) {
		r.Use(auth.RequireAuth(s.jwt))

		r.Get("/api/me", s.handleMe)
		r.Post("/api/users", s.handleCreateUser)
		r.Get("/api/files", s.handleNotImplemented)
	})

	return r
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
go test ./internal/api/rest/ -v -run TestAuth
```

Expected: all 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/api/rest/
git commit -m "feat: add auth endpoints (login, register, refresh)"
```

---

### Task 17: File Management Endpoints

**Files:**
- Create: `internal/api/rest/files.go`
- Create: `internal/api/rest/files_test.go`

- [ ] **Step 1: Write file endpoint tests**

Create `internal/api/rest/files_test.go`:

```go
package rest

import (
	"bytes"
	"encoding/json"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"testing"

	iauth "github.com/NielHeesakkers/SyncVault/internal/auth"
)

func authedRequest(t *testing.T, env *testEnv, method, path string, body io.Reader) (*http.Request, string) {
	t.Helper()
	pw, _ := iauth.HashPassword("pass")
	u, _ := env.db.CreateUser("testadmin", "ta@test.com", pw, "admin")
	token, _, _ := env.jwt.GenerateTokens(u.ID, "testadmin", "admin")
	req := httptest.NewRequest(method, path, body)
	req.Header.Set("Authorization", "Bearer "+token)
	return req, u.ID
}

func TestFiles_CreateFolder(t *testing.T) {
	env := setupTest(t)
	body := `{"name":"Documents","is_dir":true}`
	req, _ := authedRequest(t, env, "POST", "/api/files", bytes.NewBufferString(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestFiles_ListRoot(t *testing.T) {
	env := setupTest(t)
	pw, _ := iauth.HashPassword("pass")
	u, _ := env.db.CreateUser("lister", "l@test.com", pw, "user")
	token, _, _ := env.jwt.GenerateTokens(u.ID, "lister", "user")

	env.db.CreateFile("", u.ID, "folder1", true, 0, "", "")
	env.db.CreateFile("", u.ID, "file1.txt", false, 100, "h1", "text/plain")

	req := httptest.NewRequest("GET", "/api/files", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var resp map[string]interface{}
	json.Unmarshal(rec.Body.Bytes(), &resp)
	files := resp["files"].([]interface{})
	if len(files) != 2 {
		t.Fatalf("expected 2 items, got %d", len(files))
	}
}

func TestFiles_Upload(t *testing.T) {
	env := setupTest(t)
	pw, _ := iauth.HashPassword("pass")
	u, _ := env.db.CreateUser("uploader", "up@test.com", pw, "user")
	token, _, _ := env.jwt.GenerateTokens(u.ID, "uploader", "user")

	// Create multipart upload
	var buf bytes.Buffer
	writer := multipart.NewWriter(&buf)
	part, _ := writer.CreateFormFile("file", "test.txt")
	part.Write([]byte("file content here"))
	writer.Close()

	req := httptest.NewRequest("POST", "/api/files/upload", &buf)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestFiles_Download(t *testing.T) {
	env := setupTest(t)
	pw, _ := iauth.HashPassword("pass")
	u, _ := env.db.CreateUser("downloader", "dl@test.com", pw, "user")
	token, _, _ := env.jwt.GenerateTokens(u.ID, "downloader", "user")

	// Store content and create file record
	content := []byte("downloadable content")
	hash, _, _ := env.store.Put(bytes.NewReader(content))
	file, _ := env.db.CreateFile("", u.ID, "dl.txt", false, int64(len(content)), hash, "text/plain")

	req := httptest.NewRequest("GET", "/api/files/"+file.ID+"/download", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	env.server.Router().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	if !bytes.Equal(rec.Body.Bytes(), content) {
		t.Fatal("downloaded content does not match")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/api/rest/ -v -run TestFiles
```

Expected: FAIL — routes not registered.

- [ ] **Step 3: Implement files.go and register routes**

Create `internal/api/rest/files.go`:

```go
package rest

import (
	"bytes"
	"io"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/NielHeesakkers/SyncVault/internal/auth"
)

type createFileRequest struct {
	Name     string `json:"name"`
	ParentID string `json:"parent_id"`
	IsDir    bool   `json:"is_dir"`
}

func (s *Server) handleListFiles(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	parentID := r.URL.Query().Get("parent_id")

	files, err := s.db.ListChildren(parentID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}

	// Filter to user's own files (simple ownership check)
	var result []map[string]interface{}
	for _, f := range files {
		if f.OwnerID == claims.UserID || claims.Role == "admin" {
			result = append(result, map[string]interface{}{
				"id":           f.ID,
				"name":         f.Name,
				"is_dir":       f.IsDir,
				"size":         f.Size,
				"content_hash": f.ContentHash,
				"mime_type":    f.MimeType,
				"created_at":   f.CreatedAt,
				"updated_at":   f.UpdatedAt,
			})
		}
	}
	if result == nil {
		result = []map[string]interface{}{}
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"files": result})
}

func (s *Server) handleCreateFile(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	var req createFileRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request"})
		return
	}

	file, err := s.db.CreateFile(req.ParentID, claims.UserID, req.Name, req.IsDir, 0, "", "")
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}

	writeJSON(w, http.StatusCreated, map[string]interface{}{
		"id":     file.ID,
		"name":   file.Name,
		"is_dir": file.IsDir,
	})
}

func (s *Server) handleUpload(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())

	if err := r.ParseMultipartForm(32 << 20); err != nil { // 32MB max
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid multipart form"})
		return
	}

	file, header, err := r.FormFile("file")
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing file field"})
		return
	}
	defer file.Close()

	parentID := r.FormValue("parent_id")

	// Read file content
	data, err := io.ReadAll(file)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to read file"})
		return
	}

	// Store in content-addressable storage
	hash, size, err := s.store.Put(bytes.NewReader(data))
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to store file"})
		return
	}

	// Detect MIME type
	mimeType := http.DetectContentType(data[:min(512, len(data))])

	// Create file record
	meta, err := s.db.CreateFile(parentID, claims.UserID, header.Filename, false, size, hash, mimeType)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}

	// Create first version
	s.db.CreateVersion(meta.ID, 1, hash, "", size, claims.UserID)

	writeJSON(w, http.StatusCreated, map[string]interface{}{
		"id":           meta.ID,
		"name":         meta.Name,
		"size":         size,
		"content_hash": hash,
		"mime_type":    mimeType,
	})
}

func (s *Server) handleDownload(w http.ResponseWriter, r *http.Request) {
	fileID := chi.URLParam(r, "id")

	meta, err := s.db.GetFileByID(fileID)
	if err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "file not found"})
		return
	}

	w.Header().Set("Content-Type", meta.MimeType)
	w.Header().Set("Content-Disposition", "attachment; filename=\""+meta.Name+"\"")

	if err := s.store.Get(meta.ContentHash, w); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to read file"})
		return
	}
}

// Note: min() is a builtin in Go 1.22+, no custom helper needed
```

Update routes in `internal/api/rest/server.go` `setupRoutes()`:

```go
func (s *Server) setupRoutes() chi.Router {
	r := chi.NewRouter()
	r.Use(CORSMiddleware)
	r.Use(LoggingMiddleware)

	// Public routes
	r.Get("/api/health", s.handleHealth)
	r.Post("/api/auth/login", s.handleLogin)
	r.Post("/api/auth/refresh", s.handleRefresh)

	// Protected routes
	r.Group(func(r chi.Router) {
		r.Use(auth.RequireAuth(s.jwt))

		r.Get("/api/me", s.handleMe)
		r.Post("/api/users", s.handleCreateUser)

		// Files
		r.Get("/api/files", s.handleListFiles)
		r.Post("/api/files", s.handleCreateFile)
		r.Post("/api/files/upload", s.handleUpload)
		r.Get("/api/files/{id}/download", s.handleDownload)
	})

	return r
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
go test ./internal/api/rest/ -v -run TestFiles
```

Expected: all 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/api/rest/
git commit -m "feat: add file management REST endpoints (list, create, upload, download)"
```

---

**End of Chunk 5**

---

## Chunk 6: Docker + Main Wiring + Integration Test

### Task 18: Wire Everything in main.go

**Files:**
- Modify: `cmd/server/main.go`

- [ ] **Step 1: Update main.go to wire all components**

Replace `cmd/server/main.go`:

```go
package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
	"github.com/NielHeesakkers/SyncVault/internal/config"
	"github.com/NielHeesakkers/SyncVault/internal/metadata"
	"github.com/NielHeesakkers/SyncVault/internal/storage"
	restapi "github.com/NielHeesakkers/SyncVault/internal/api/rest"
)

func main() {
	cfg, err := config.Load(config.Default().ConfigPath())
	if err != nil {
		log.Fatalf("failed to load config: %v", err)
	}

	// Ensure data directories exist
	for _, dir := range []string{cfg.DataDir, cfg.StoragePath()} {
		if err := os.MkdirAll(dir, 0755); err != nil {
			log.Fatalf("failed to create directory %s: %v", dir, err)
		}
	}

	// Initialize database
	db, err := metadata.Open(cfg.DBPath())
	if err != nil {
		log.Fatalf("failed to open database: %v", err)
	}
	defer db.Close()

	// Initialize storage
	store, err := storage.NewStore(cfg.StoragePath(), cfg.MaxChunkSize)
	if err != nil {
		log.Fatalf("failed to create store: %v", err)
	}

	// Initialize auth
	jwtSecret := cfg.JWTSecret
	if jwtSecret == "" {
		jwtSecret = "syncvault-dev-secret-change-in-production!"
		log.Println("WARNING: using default JWT secret. Set SYNCVAULT_JWT_SECRET in production.")
	}
	jwt := auth.NewJWT(jwtSecret)

	// Create default admin user if no users exist
	users, _ := db.ListUsers()
	if len(users) == 0 {
		pw, _ := auth.HashPassword("admin")
		db.CreateUser("admin", "admin@syncvault.local", pw, "admin")
		log.Println("Created default admin user (username: admin, password: admin)")
	}

	// Start REST API server
	restServer := restapi.NewServer(db, store, jwt)
	httpServer := &http.Server{
		Addr:    fmt.Sprintf(":%d", cfg.HTTPPort),
		Handler: restServer.Router(),
	}

	// Graceful shutdown
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		listener, err := net.Listen("tcp", httpServer.Addr)
		if err != nil {
			log.Fatalf("failed to listen: %v", err)
		}
		log.Printf("SyncVault server started")
		log.Printf("  REST API: http://localhost:%d", cfg.HTTPPort)
		log.Printf("  Data dir: %s", cfg.DataDir)

		if cfg.TLSCertFile != "" && cfg.TLSKeyFile != "" {
			log.Printf("  TLS: enabled")
			err = httpServer.ServeTLS(listener, cfg.TLSCertFile, cfg.TLSKeyFile)
		} else {
			err = httpServer.Serve(listener)
		}
		if err != nil && err != http.ErrServerClosed {
			log.Fatalf("server error: %v", err)
		}
	}()

	<-ctx.Done()
	log.Println("Shutting down...")
	httpServer.Shutdown(context.Background())
}
```

- [ ] **Step 2: Verify it compiles**

```bash
go build ./cmd/server/
```

Expected: compiles without errors.

- [ ] **Step 3: Commit**

```bash
git add cmd/server/main.go
git commit -m "feat: wire all components in main.go with graceful shutdown"
```

---

### Task 19: Dockerfile + docker-compose.yml

**Files:**
- Create: `Dockerfile`
- Create: `docker-compose.yml`

- [ ] **Step 1: Write Dockerfile**

Create `Dockerfile`:

```dockerfile
FROM golang:1.22-alpine AS builder

WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o syncvault ./cmd/server

FROM alpine:3.19

RUN apk add --no-cache ca-certificates tzdata
RUN adduser -D -u 1000 syncvault

COPY --from=builder /build/syncvault /usr/local/bin/syncvault

USER syncvault
VOLUME /data
EXPOSE 8080 6690

ENV SYNCVAULT_DATA_DIR=/data

ENTRYPOINT ["syncvault"]
```

- [ ] **Step 2: Write docker-compose.yml**

Create `docker-compose.yml`:

```yaml
version: "3.8"

services:
  syncvault:
    build: .
    ports:
      - "8080:8080"
      - "6690:6690"
    volumes:
      - syncvault-data:/data
    environment:
      - SYNCVAULT_JWT_SECRET=${SYNCVAULT_JWT_SECRET:-change-me-in-production}
      - SYNCVAULT_HTTP_PORT=8080
      - SYNCVAULT_GRPC_PORT=6690
    restart: unless-stopped

volumes:
  syncvault-data:
```

- [ ] **Step 3: Add Docker entries to .gitignore**

Append to `.gitignore`:

```
bin/
tmp/
.superpowers/
```

- [ ] **Step 4: Verify Docker build**

```bash
docker build -t syncvault:dev .
```

Expected: image builds successfully.

- [ ] **Step 5: Commit**

```bash
git add Dockerfile docker-compose.yml .gitignore
git commit -m "feat: add Dockerfile and docker-compose.yml for single-container deployment"
```

---

### Task 20: Integration Test

**Files:**
- Create: `tests/integration/server_test.go`

- [ ] **Step 1: Write integration test**

Create `tests/integration/server_test.go`:

```go
package integration

import (
	"bytes"
	"encoding/json"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
	"github.com/NielHeesakkers/SyncVault/internal/metadata"
	"github.com/NielHeesakkers/SyncVault/internal/storage"
	restapi "github.com/NielHeesakkers/SyncVault/internal/api/rest"
)

func setupIntegration(t *testing.T) (*httptest.Server, *metadata.DB) {
	t.Helper()
	dir := t.TempDir()

	db, err := metadata.Open(filepath.Join(dir, "vault.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })

	store, err := storage.NewStore(filepath.Join(dir, "chunks"), 1024*1024)
	if err != nil {
		t.Fatal(err)
	}

	jwt := auth.NewJWT("integration-test-secret-32-bytes!!")

	// Create admin user
	pw, _ := auth.HashPassword("adminpass")
	db.CreateUser("admin", "admin@test.com", pw, "admin")

	srv := restapi.NewServer(db, store, jwt)
	ts := httptest.NewServer(srv.Router())
	t.Cleanup(ts.Close)

	return ts, db
}

func login(t *testing.T, ts *httptest.Server, username, password string) string {
	t.Helper()
	body := map[string]string{"username": username, "password": password}
	b, _ := json.Marshal(body)
	resp, err := http.Post(ts.URL+"/api/auth/login", "application/json", bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("login failed: %d", resp.StatusCode)
	}
	var result map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&result)
	return result["access_token"].(string)
}

func TestIntegration_FullWorkflow(t *testing.T) {
	ts, _ := setupIntegration(t)

	// 1. Login as admin
	token := login(t, ts, "admin", "adminpass")

	// 2. Create a new user
	createUserBody, _ := json.Marshal(map[string]string{
		"username": "alice", "email": "alice@test.com", "password": "alicepass",
	})
	req, _ := http.NewRequest("POST", ts.URL+"/api/users", bytes.NewReader(createUserBody))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	resp, _ := http.DefaultClient.Do(req)
	if resp.StatusCode != 201 {
		t.Fatalf("create user: expected 201, got %d", resp.StatusCode)
	}
	resp.Body.Close()

	// 3. Login as alice
	aliceToken := login(t, ts, "alice", "alicepass")

	// 4. Create a folder
	folderBody, _ := json.Marshal(map[string]interface{}{"name": "MyDocs", "is_dir": true})
	req, _ = http.NewRequest("POST", ts.URL+"/api/files", bytes.NewReader(folderBody))
	req.Header.Set("Authorization", "Bearer "+aliceToken)
	req.Header.Set("Content-Type", "application/json")
	resp, _ = http.DefaultClient.Do(req)
	if resp.StatusCode != 201 {
		t.Fatalf("create folder: expected 201, got %d", resp.StatusCode)
	}
	resp.Body.Close()

	// 5. Upload a file
	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	part, _ := w.CreateFormFile("file", "hello.txt")
	part.Write([]byte("Hello SyncVault!"))
	w.Close()

	req, _ = http.NewRequest("POST", ts.URL+"/api/files/upload", &buf)
	req.Header.Set("Authorization", "Bearer "+aliceToken)
	req.Header.Set("Content-Type", w.FormDataContentType())
	resp, _ = http.DefaultClient.Do(req)
	if resp.StatusCode != 201 {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("upload: expected 201, got %d: %s", resp.StatusCode, body)
	}
	var uploadResult map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&uploadResult)
	resp.Body.Close()
	fileID := uploadResult["id"].(string)

	// 6. Download the file
	req, _ = http.NewRequest("GET", ts.URL+"/api/files/"+fileID+"/download", nil)
	req.Header.Set("Authorization", "Bearer "+aliceToken)
	resp, _ = http.DefaultClient.Do(req)
	if resp.StatusCode != 200 {
		t.Fatalf("download: expected 200, got %d", resp.StatusCode)
	}
	downloaded, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if string(downloaded) != "Hello SyncVault!" {
		t.Fatalf("download content mismatch: %s", downloaded)
	}

	// 7. List files
	req, _ = http.NewRequest("GET", ts.URL+"/api/files", nil)
	req.Header.Set("Authorization", "Bearer "+aliceToken)
	resp, _ = http.DefaultClient.Do(req)
	if resp.StatusCode != 200 {
		t.Fatalf("list: expected 200, got %d", resp.StatusCode)
	}
	resp.Body.Close()

	// 8. Health check (public)
	resp, _ = http.Get(ts.URL + "/api/health")
	if resp.StatusCode != 200 {
		t.Fatalf("health: expected 200, got %d", resp.StatusCode)
	}
	resp.Body.Close()
}
```

- [ ] **Step 2: Run integration test**

```bash
go test ./tests/integration/ -v -run TestIntegration
```

Expected: PASS — full workflow completes.

- [ ] **Step 3: Run all tests**

```bash
go test ./... -v -count=1
```

Expected: ALL tests PASS across all packages.

- [ ] **Step 4: Commit**

```bash
git add tests/
git commit -m "feat: add full integration test for server workflow"
```

---

### Task 21: Final Polish + Push

- [ ] **Step 1: Update Makefile**

Update `Makefile`:

```makefile
.PHONY: build run test clean docker

build:
	go build -o bin/syncvault ./cmd/server

run: build
	SYNCVAULT_DATA_DIR=./tmp/data ./bin/syncvault

test:
	go test ./... -v -count=1

clean:
	rm -rf bin/ tmp/

docker:
	docker build -t syncvault:dev .

docker-run: docker
	docker run -p 8080:8080 -p 6690:6690 -v syncvault-data:/data syncvault:dev
```

- [ ] **Step 2: Run all tests one final time**

```bash
make test
```

Expected: ALL tests PASS.

- [ ] **Step 3: Commit and push**

```bash
git add Makefile
git commit -m "feat: update Makefile with docker targets"
git push origin main
```

---

**End of Chunk 6**

---

## Deferred to Follow-Up Plan

The following components from the spec are intentionally deferred to separate implementation plans:

- **gRPC sync API** (`proto/syncvault/*.proto`, `internal/api/grpc/*`): The gRPC service is only consumed by the macOS sync client (phase 3). It will be planned and built when the macOS client is designed, ensuring the proto definitions match the actual sync protocol needs.
- **File watcher** (`internal/watcher/`): The fsnotify-based file watcher is primarily needed for real-time change broadcasting to sync clients. Will be implemented alongside the gRPC sync service.
- **Sync engine** (`internal/sync/`): Conflict resolution, selective sync rules, and tree comparison are sync-client features. Deferred to the macOS client phase.
- **Retention policy scheduler**: The metadata CRUD and rotation algorithms are in place. The automatic scheduled cleanup job will be added when the server runs long enough to need it (before web UI phase).
- **Quota enforcement**: Quota tracking is in the database. Enforcement on upload will be added to the REST API in the web UI phase.

This plan delivers a working server with REST API, file storage, versioning, auth, user management, team folders, share links, and Docker deployment — sufficient to build the web UI on top of.
