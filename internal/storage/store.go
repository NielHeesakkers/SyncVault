package storage

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

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

// chunkPath returns the path for a chunk identified by its hash.
func (s *Store) chunkPath(hash string) string {
	return filepath.Join(s.dir, hash[:2], hash)
}

// manifestPath returns the path for the manifest file for a given file hash.
func (s *Store) manifestPath(hash string) string {
	return filepath.Join(s.dir, hash[:2], hash+".manifest")
}

// Put reads all data from r, splits it into chunks, stores each chunk by its hash,
// writes a manifest, and returns the overall file hash, total size, and any error.
func (s *Store) Put(r io.Reader) (fileHash string, size int64, err error) {
	// Read all data first to compute the file-level hash and chunk it.
	data, err := io.ReadAll(r)
	if err != nil {
		return "", 0, fmt.Errorf("storage: read input: %w", err)
	}

	// Compute overall file hash.
	h := sha256.Sum256(data)
	fileHash = hex.EncodeToString(h[:])
	size = int64(len(data))

	// Chunk the data.
	chunks, err := s.chunker.Chunk(strings.NewReader(string(data)))
	if err != nil {
		return "", 0, fmt.Errorf("storage: chunk data: %w", err)
	}

	// Store each chunk.
	for _, chunk := range chunks {
		cp := s.chunkPath(chunk.Hash)
		if err := os.MkdirAll(filepath.Dir(cp), 0755); err != nil {
			return "", 0, fmt.Errorf("storage: create chunk dir: %w", err)
		}
		// Only write if not already present (deduplication).
		if _, statErr := os.Stat(cp); os.IsNotExist(statErr) {
			if err := os.WriteFile(cp, chunk.Data, 0644); err != nil {
				return "", 0, fmt.Errorf("storage: write chunk: %w", err)
			}
		}
	}

	// Write manifest: one line per chunk — "<index> <hash> <size>"
	mp := s.manifestPath(fileHash)
	if err := os.MkdirAll(filepath.Dir(mp), 0755); err != nil {
		return "", 0, fmt.Errorf("storage: create manifest dir: %w", err)
	}

	var sb strings.Builder
	for _, chunk := range chunks {
		sb.WriteString(fmt.Sprintf("%d %s %d\n", chunk.Index, chunk.Hash, chunk.Size))
	}
	if err := os.WriteFile(mp, []byte(sb.String()), 0644); err != nil {
		return "", 0, fmt.Errorf("storage: write manifest: %w", err)
	}

	return fileHash, size, nil
}

// Get reads the manifest for fileHash, reassembles the chunks in order, and writes the data to w.
func (s *Store) Get(fileHash string, w io.Writer) error {
	mp := s.manifestPath(fileHash)
	f, err := os.Open(mp)
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
	// Simple insertion sort since chunk count is typically small.
	for i := 1; i < len(entries); i++ {
		for j := i; j > 0 && entries[j].index < entries[j-1].index; j-- {
			entries[j], entries[j-1] = entries[j-1], entries[j]
		}
	}

	for _, e := range entries {
		cp := s.chunkPath(e.hash)
		data, err := os.ReadFile(cp)
		if err != nil {
			return fmt.Errorf("storage: read chunk %s: %w", e.hash, err)
		}
		if _, err := w.Write(data); err != nil {
			return fmt.Errorf("storage: write to output: %w", err)
		}
	}

	return nil
}

// Delete removes the manifest and all referenced chunks for fileHash.
// Note: there is no reference counting, so shared chunks are also deleted.
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

	// Remove chunks.
	for _, hash := range chunkHashes {
		cp := s.chunkPath(hash)
		if err := os.Remove(cp); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("storage: remove chunk %s: %w", hash, err)
		}
	}

	return nil
}
