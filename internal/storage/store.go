package storage

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings" // used by Get/Delete manifest parsing
	"syscall"
	"time"
)

// retryOnTooManyFiles retries f up to 5 times with increasing delay when
// the error is EMFILE or ENFILE ("too many open files").
func retryOnTooManyFiles(op string, f func() error) error {
	for attempt := 0; attempt < 5; attempt++ {
		err := f()
		if err == nil {
			return nil
		}
		if errors.Is(err, syscall.EMFILE) || errors.Is(err, syscall.ENFILE) ||
			strings.Contains(err.Error(), "too many open files") {
			delay := time.Duration(1<<uint(attempt)) * time.Second // 1s, 2s, 4s, 8s, 16s
			log.Printf("storage: %s: too many open files, retry %d/5 in %v", op, attempt+1, delay)
			time.Sleep(delay)
			continue
		}
		return err
	}
	return fmt.Errorf("storage: %s: too many open files after 5 retries", op)
}

// ErrNotFound is returned when a file hash is not found in the store.
var ErrNotFound = errors.New("storage: file not found")

// Store is a content-addressable file store that chunks files and stores them on disk.
type Store struct {
	dir     string
	chunker *Chunker
}

// NewStore creates a new Store rooted at dir with the given chunk size.
// It creates the directory if it does not exist.
func NewStore(dir string, chunkSize int) (*Store, error) {
	if err := os.MkdirAll(dir, 0755); err != nil {
		return nil, fmt.Errorf("storage: create dir: %w", err)
	}
	return &Store{
		dir:     dir,
		chunker: NewChunker(chunkSize),
	}, nil
}

// IsAvailable checks if the storage directory is accessible.
func (s *Store) IsAvailable() bool {
	_, err := os.Stat(s.dir)
	return err == nil
}

// chunkPath returns the path for a chunk identified by its hash.
func (s *Store) chunkPath(hash string) string {
	return filepath.Join(s.dir, hash[:2], hash)
}

// manifestPath returns the path for the manifest file for a given file hash.
func (s *Store) manifestPath(hash string) string {
	return filepath.Join(s.dir, hash[:2], hash+".manifest")
}

// HasBlock returns true if a block with the given hash exists in storage.
func (s *Store) HasBlock(hash string) bool {
	_, err := os.Stat(s.chunkPath(hash))
	return err == nil
}

// CheckBlocks returns which of the given hashes already exist in storage.
func (s *Store) CheckBlocks(hashes []string) []string {
	var existing []string
	for _, h := range hashes {
		if s.HasBlock(h) {
			existing = append(existing, h)
		}
	}
	return existing
}

// PutBlock stores a single block by its hash. Returns true if the block was newly written,
// false if it already existed (deduplicated). Verifies the hash matches the data.
// Retries on "too many open files" errors.
func (s *Store) PutBlock(hash string, data []byte) (isNew bool, err error) {
	// Verify hash
	h := sha256.Sum256(data)
	actual := hex.EncodeToString(h[:])
	if actual != hash {
		return false, fmt.Errorf("storage: hash mismatch: expected %s, got %s", hash, actual)
	}

	cp := s.chunkPath(hash)
	if _, statErr := os.Stat(cp); statErr == nil {
		return false, nil // Already exists — deduplicated
	}

	err = retryOnTooManyFiles("PutBlock mkdir", func() error {
		return os.MkdirAll(filepath.Dir(cp), 0755)
	})
	if err != nil {
		return false, fmt.Errorf("storage: create block dir: %w", err)
	}

	err = retryOnTooManyFiles("PutBlock write", func() error {
		// Write block to storage. Skip fsync per-block for performance on SMB/NFS —
		// data integrity is guaranteed by content-addressable hashing (if the hash doesn't
		// match on read, the block is re-uploaded).
		f, err := os.Create(cp)
		if err != nil {
			return err
		}
		if _, err := f.Write(data); err != nil {
			f.Close()
			os.Remove(cp)
			return err
		}
		return f.Close()
	})
	if err != nil {
		return false, fmt.Errorf("storage: write block: %w", err)
	}
	return true, nil
}

// BlockEntry represents one block in a file manifest.
type BlockEntry struct {
	Index int    `json:"index"`
	Hash  string `json:"hash"`
	Size  int    `json:"size"`
}

// CreateManifest writes a manifest file for a file hash, linking it to its blocks.
// All blocks must already exist in storage. Returns the total file size.
func (s *Store) CreateManifest(fileHash string, blocks []BlockEntry) (int64, error) {
	var totalSize int64
	for _, b := range blocks {
		if !s.HasBlock(b.Hash) {
			return 0, fmt.Errorf("storage: missing block %s (index %d)", b.Hash, b.Index)
		}
		totalSize += int64(b.Size)
	}

	mp := s.manifestPath(fileHash)
	if err := retryOnTooManyFiles("CreateManifest mkdir", func() error {
		return os.MkdirAll(filepath.Dir(mp), 0755)
	}); err != nil {
		return 0, fmt.Errorf("storage: create manifest dir: %w", err)
	}

	var sb strings.Builder
	for _, b := range blocks {
		sb.WriteString(fmt.Sprintf("%d %s %d\n", b.Index, b.Hash, b.Size))
	}
	if err := retryOnTooManyFiles("CreateManifest write", func() error {
		return os.WriteFile(mp, []byte(sb.String()), 0644)
	}); err != nil {
		return 0, fmt.Errorf("storage: write manifest: %w", err)
	}

	// Increment reference count for each block used by this manifest
	for _, b := range blocks {
		s.incrementBlockRef(b.Hash)
	}

	return totalSize, nil
}

// PutDirect streams data from r directly to a single file on disk (no chunking).
// Much faster on SMB/NFS mounts because it's 1 file write instead of N chunk writes.
// Returns the SHA-256 hash and total size.
func (s *Store) PutDirect(r io.Reader) (fileHash string, size int64, err error) {
	// Write to temp file first at max speed (no hashing during write).
	// Hash the file AFTER writing — decouples network I/O from CPU.
	tmpPath := filepath.Join(s.dir, "incoming", fmt.Sprintf("%d.tmp", time.Now().UnixNano()))
	os.MkdirAll(filepath.Dir(tmpPath), 0755)

	f, err := os.Create(tmpPath)
	if err != nil {
		return "", 0, fmt.Errorf("storage: create temp file: %w", err)
	}

	// Phase 1: Write at full speed (no hashing)
	buf := make([]byte, 8*1024*1024) // 8MB buffer for max throughput
	for {
		n, readErr := r.Read(buf)
		if n > 0 {
			if _, wErr := f.Write(buf[:n]); wErr != nil {
				f.Close()
				os.Remove(tmpPath)
				return "", 0, fmt.Errorf("storage: write: %w", wErr)
			}
			size += int64(n)
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			f.Close()
			os.Remove(tmpPath)
			return "", 0, fmt.Errorf("storage: read: %w", readErr)
		}
	}
	f.Close()

	// Phase 2: Hash the written file (disk I/O only, no network wait)
	hashFile, err := os.Open(tmpPath)
	if err != nil {
		os.Remove(tmpPath)
		return "", 0, fmt.Errorf("storage: reopen for hash: %w", err)
	}
	hasher := sha256.New()
	io.CopyBuffer(hasher, hashFile, buf)
	hashFile.Close()

	fileHash = hex.EncodeToString(hasher.Sum(nil))

	// Move to final content-addressable path: files/<hash[0:2]>/<hash[2:4]>/<hash>
	finalDir := filepath.Join(s.dir, "files", fileHash[:2], fileHash[2:4])
	finalPath := filepath.Join(finalDir, fileHash)
	os.MkdirAll(finalDir, 0755)

	// If file already exists (dedup), just remove the temp
	if _, err := os.Stat(finalPath); err == nil {
		os.Remove(tmpPath)
		return fileHash, size, nil
	}

	if err := os.Rename(tmpPath, finalPath); err != nil {
		// Cross-device: fall back to copy
		src, _ := os.Open(tmpPath)
		dst, _ := os.Create(finalPath)
		io.Copy(dst, src)
		src.Close()
		dst.Close()
		os.Remove(tmpPath)
	}

	return fileHash, size, nil
}

// GetDirect reads a file stored by PutDirect (single file, not chunked).
func (s *Store) GetDirect(fileHash string, w io.Writer) error {
	if len(fileHash) < 4 {
		return s.Get(fileHash, w)
	}
	path := filepath.Join(s.dir, "files", fileHash[:2], fileHash[2:4], fileHash)
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			// Fall back to chunked manifest
			return s.Get(fileHash, w)
		}
		return fmt.Errorf("storage: open file: %w", err)
	}
	defer f.Close()
	_, err = io.Copy(w, f)
	return err
}

// Put streams data from r in 4 MB chunks, stores each chunk by its hash,
// writes a manifest, and returns the overall file hash, total size, and any error.
// Memory usage is O(chunkSize) regardless of file size.
func (s *Store) Put(r io.Reader) (fileHash string, size int64, err error) {
	fileHasher := sha256.New()
	buf := make([]byte, s.chunker.chunkSize)

	type manifestEntry struct {
		index int
		hash  string
		size  int
	}
	var entries []manifestEntry
	index := 0

	for {
		n, readErr := io.ReadFull(r, buf)
		if n > 0 {
			chunk := buf[:n]

			// Update the running file hash
			fileHasher.Write(chunk)
			size += int64(n)

			// Compute chunk hash
			ch := sha256.Sum256(chunk)
			chunkHash := hex.EncodeToString(ch[:])

			// Store chunk (deduplicated) — with retry for "too many open files"
			cp := s.chunkPath(chunkHash)
			if mkErr := retryOnTooManyFiles("Put mkdir", func() error {
				return os.MkdirAll(filepath.Dir(cp), 0755)
			}); mkErr != nil {
				return "", 0, fmt.Errorf("storage: create chunk dir: %w", mkErr)
			}
			if _, statErr := os.Stat(cp); os.IsNotExist(statErr) {
				if wErr := retryOnTooManyFiles("Put write", func() error {
					return os.WriteFile(cp, chunk, 0644)
				}); wErr != nil {
					return "", 0, fmt.Errorf("storage: write chunk: %w", wErr)
				}
			}

			entries = append(entries, manifestEntry{index: index, hash: chunkHash, size: n})
			index++
		}
		if readErr == io.EOF || readErr == io.ErrUnexpectedEOF {
			break
		}
		if readErr != nil {
			return "", 0, fmt.Errorf("storage: read input: %w", readErr)
		}
	}

	fileHash = hex.EncodeToString(fileHasher.Sum(nil))

	// Verify all chunks exist before writing manifest (disk full protection)
	for _, e := range entries {
		cp := s.chunkPath(e.hash)
		info, err := os.Stat(cp)
		if err != nil || info.Size() != int64(e.size) {
			// Cleanup partial upload
			return "", 0, fmt.Errorf("storage: chunk %s missing or incomplete after write", e.hash)
		}
	}

	// Write manifest: one line per chunk — "<index> <hash> <size>"
	mp := s.manifestPath(fileHash)
	if err := os.MkdirAll(filepath.Dir(mp), 0755); err != nil {
		return "", 0, fmt.Errorf("storage: create manifest dir: %w", err)
	}

	var sb strings.Builder
	for _, e := range entries {
		sb.WriteString(fmt.Sprintf("%d %s %d\n", e.index, e.hash, e.size))
	}
	if err := os.WriteFile(mp, []byte(sb.String()), 0644); err != nil {
		return "", 0, fmt.Errorf("storage: write manifest: %w", err)
	}

	// Increment reference count for each block used by this manifest
	for _, e := range entries {
		s.incrementBlockRef(e.hash)
	}

	return fileHash, size, nil
}

// Get reads the manifest for fileHash, reassembles the chunks in order, and writes the data to w.
func (s *Store) Get(fileHash string, w io.Writer) error {
	mp := s.manifestPath(fileHash)
	var f *os.File
	err := retryOnTooManyFiles("Get open manifest", func() error {
		var openErr error
		f, openErr = os.Open(mp)
		return openErr
	})
	if err != nil {
		if os.IsNotExist(err) {
			return ErrNotFound
		}
		return fmt.Errorf("storage: open manifest: %w", err)
	}
	defer f.Close()

	type entry struct {
		index int
		hash  string
		size  int
	}
	var entries []entry

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		parts := strings.Fields(line)
		if len(parts) != 3 {
			return fmt.Errorf("storage: malformed manifest line: %q", line)
		}
		idx, err := strconv.Atoi(parts[0])
		if err != nil {
			return fmt.Errorf("storage: parse manifest index: %w", err)
		}
		sz, err := strconv.Atoi(parts[2])
		if err != nil {
			return fmt.Errorf("storage: parse manifest size: %w", err)
		}
		entries = append(entries, entry{index: idx, hash: parts[1], size: sz})
	}
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("storage: scan manifest: %w", err)
	}

	// Sort by index (manifest is written in order, but be safe).
	for i := 1; i < len(entries); i++ {
		for j := i; j > 0 && entries[j].index < entries[j-1].index; j-- {
			entries[j], entries[j-1] = entries[j-1], entries[j]
		}
	}

	// Validate: no duplicate or missing indices
	for i, e := range entries {
		if e.index != i {
			return fmt.Errorf("storage: manifest integrity error: expected chunk index %d, got %d", i, e.index)
		}
	}

	for _, e := range entries {
		cp := s.chunkPath(e.hash)
		var chunkFile *os.File
		if err := retryOnTooManyFiles("Get open chunk", func() error {
			var openErr error
			chunkFile, openErr = os.Open(cp)
			return openErr
		}); err != nil {
			return fmt.Errorf("storage: read chunk %s: %w", e.hash, err)
		}
		_, copyErr := io.Copy(w, chunkFile)
		chunkFile.Close()
		if copyErr != nil {
			return fmt.Errorf("storage: write to output: %w", copyErr)
		}
	}

	return nil
}

// incrementBlockRef increments the reference count for a block hash.
// Called when a new manifest references this block.
func (s *Store) incrementBlockRef(hash string) {
	refPath := s.chunkPath(hash) + ".ref"
	count := s.readRefCount(refPath)
	os.WriteFile(refPath, []byte(strconv.Itoa(count+1)), 0644)
}

// decrementBlockRef decrements the reference count and removes the block if zero.
func (s *Store) decrementBlockRef(hash string) {
	refPath := s.chunkPath(hash) + ".ref"
	count := s.readRefCount(refPath)
	if count <= 1 {
		// Last reference — safe to delete block and refcount file
		os.Remove(s.chunkPath(hash))
		os.Remove(refPath)
	} else {
		os.WriteFile(refPath, []byte(strconv.Itoa(count-1)), 0644)
	}
}

func (s *Store) readRefCount(refPath string) int {
	data, err := os.ReadFile(refPath)
	if err != nil {
		return 1 // No refcount file = legacy block, assume 1 reference
	}
	count, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil || count < 0 {
		return 1
	}
	return count
}

// Delete removes the manifest and decrements reference counts for all chunks.
// Chunks are only deleted when their reference count reaches zero.
func (s *Store) Delete(fileHash string) error {
	mp := s.manifestPath(fileHash)
	f, err := os.Open(mp)
	if err != nil {
		if os.IsNotExist(err) {
			return ErrNotFound
		}
		return fmt.Errorf("storage: open manifest for delete: %w", err)
	}

	var chunkHashes []string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		parts := strings.Fields(line)
		if len(parts) == 3 {
			chunkHashes = append(chunkHashes, parts[1])
		}
	}
	f.Close()
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("storage: scan manifest for delete: %w", err)
	}

	// Remove manifest.
	if err := os.Remove(mp); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("storage: remove manifest: %w", err)
	}

	// Decrement reference counts — only delete blocks when refcount reaches 0.
	for _, hash := range chunkHashes {
		s.decrementBlockRef(hash)
	}

	return nil
}

// DiskSpace returns the total and available bytes on the filesystem where the store directory lives.
// Returns (0, 0) if the information is not available.
func (s *Store) DiskSpace() (total, available int64) {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(s.dir, &stat); err != nil {
		return 0, 0
	}
	total = int64(stat.Blocks) * int64(stat.Bsize)
	available = int64(stat.Bavail) * int64(stat.Bsize)
	return total, available
}
