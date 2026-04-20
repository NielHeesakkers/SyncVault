package rest

import (
	"archive/tar"
	"io"
	"log"
	"net/http"
	"path/filepath"
	"strings"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
)

// handleBatchTar handles POST /api/files/batch-tar?parent_id=X.
// Body is a raw tar stream containing multiple files. The server parses the tar
// stream, stores each file via PutDirect (content-addressable, streamed to disk),
// and creates DB records under the given parent_id.
//
// This is 10-30× faster than individual uploads for directories with many small
// files because it eliminates TCP handshake + HTTP headers per file.
//
// Directory entries in the tar are skipped — parents are ensured lazily via
// basename path components. Files with paths containing ".." or absolute paths
// are rejected.
func (s *Server) handleBatchTar(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	rootParentID := r.URL.Query().Get("parent_id")

	tr := tar.NewReader(r.Body)

	type tarResult struct {
		RelativePath string       `json:"relative_path"`
		File         fileResponse `json:"file,omitempty"`
		Error        string       `json:"error,omitempty"`
	}
	var results []tarResult

	// Cache parent folder IDs so we don't hit the DB for every file in the same subdir
	folderCache := map[string]string{"": rootParentID}

	// Limit overall body size: 2 GB absolute cap to prevent DoS
	const maxTarSize int64 = 2 << 30
	limitedBody := http.MaxBytesReader(w, r.Body, maxTarSize)
	tr = tar.NewReader(limitedBody)

	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "malformed tar: " + err.Error()})
			return
		}

		relPath := filepath.Clean(hdr.Name)
		if strings.HasPrefix(relPath, "/") || strings.HasPrefix(relPath, "..") || strings.Contains(relPath, "/../") {
			results = append(results, tarResult{RelativePath: hdr.Name, Error: "path traversal rejected"})
			continue
		}

		// Only regular files for now — directories are created on-demand
		if hdr.Typeflag != tar.TypeReg && hdr.Typeflag != tar.TypeRegA {
			continue
		}

		filename := filepath.Base(relPath)
		dirPath := filepath.Dir(relPath)
		if dirPath == "." {
			dirPath = ""
		}

		// Ensure parent dir chain exists on server (cached)
		parentID, ensureErr := s.ensureTarParents(dirPath, rootParentID, claims.UserID, folderCache)
		if ensureErr != nil {
			results = append(results, tarResult{RelativePath: relPath, Error: "could not create parent dir: " + ensureErr.Error()})
			// Drain the content for this file so next header can be read
			_, _ = io.Copy(io.Discard, tr)
			continue
		}

		// Detect MIME from first 512 bytes while writing to storage.
		// PutDirect streams the reader — memory bounded to O(8 MB buffer).
		peekBuf := make([]byte, 512)
		n, _ := io.ReadFull(tr, peekBuf)
		peek := peekBuf[:n]
		mimeType := http.DetectContentType(peek)

		// Prepend peeked bytes to the remaining tar content
		combined := io.MultiReader(strings.NewReader(string(peek)), tr)

		contentHash, size, putErr := s.store.PutDirect(combined)
		if putErr != nil {
			results = append(results, tarResult{RelativePath: relPath, Error: "storage failed: " + putErr.Error()})
			continue
		}

		f, createErr := s.db.CreateFile(parentID, claims.UserID, filename, false, size, contentHash, mimeType)
		if createErr != nil {
			results = append(results, tarResult{RelativePath: relPath, Error: "could not create file record: " + createErr.Error()})
			continue
		}
		_, _ = s.db.CreateVersion(f.ID, 1, contentHash, "", size, claims.UserID)

		if err := s.db.LogActivity(claims.UserID, "upload", "file", f.ID, filename+" (tar-batch)", r.RemoteAddr); err != nil {
			log.Printf("activity: %v", err)
		}

		results = append(results, tarResult{RelativePath: relPath, File: toFileResponse(*f)})
	}

	writeJSON(w, http.StatusCreated, map[string]interface{}{
		"uploaded": results,
	})
}

// ensureTarParents creates all missing parent directories for a dotted path like
// "a/b/c" under rootParentID, using the cache to avoid duplicate DB hits.
func (s *Server) ensureTarParents(dirPath, rootParentID, userID string, cache map[string]string) (string, error) {
	if dirPath == "" || dirPath == "." {
		return rootParentID, nil
	}
	if cached, ok := cache[dirPath]; ok {
		return cached, nil
	}

	// Walk the path components
	parts := strings.Split(dirPath, "/")
	currentParent := rootParentID
	currentPath := ""
	for _, part := range parts {
		if part == "" {
			continue
		}
		if currentPath == "" {
			currentPath = part
		} else {
			currentPath = currentPath + "/" + part
		}
		if cached, ok := cache[currentPath]; ok {
			currentParent = cached
			continue
		}
		// Create or find
		f, err := s.db.CreateFile(currentParent, userID, part, true, 0, "", "")
		if err != nil {
			// Probably already exists — try to find it via ListChildren
			children, listErr := s.db.ListChildren(currentParent)
			if listErr != nil {
				return "", err
			}
			found := false
			for _, child := range children {
				if child.Name == part && child.IsDir {
					currentParent = child.ID
					cache[currentPath] = child.ID
					found = true
					break
				}
			}
			if !found {
				return "", err
			}
		} else {
			currentParent = f.ID
			cache[currentPath] = f.ID
		}
	}
	return currentParent, nil
}
