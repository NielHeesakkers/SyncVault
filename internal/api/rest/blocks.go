package rest

import (
	"io"
	"net/http"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
	"github.com/NielHeesakkers/SyncVault/internal/storage"
	"github.com/go-chi/chi/v5"
)

// handlePutBlock handles PUT /api/blocks/{hash}.
// Accepts raw block data (up to 5 MB), verifies the hash, and stores it.
func (s *Server) handlePutBlock(w http.ResponseWriter, r *http.Request) {
	hash := chi.URLParam(r, "hash")
	if !isHexHash(hash, 8) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid hash"})
		return
	}

	// Limit to 5 MB (4 MB block + small overhead)
	data, err := io.ReadAll(io.LimitReader(r.Body, 5*1024*1024))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "could not read body"})
		return
	}

	isNew, err := s.store.PutBlock(hash, data)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"hash":  hash,
		"size":  len(data),
		"isNew": isNew,
	})
}

// handleCheckBlocks handles POST /api/blocks/check.
// Accepts a list of hashes, returns which ones already exist in storage.
func (s *Server) handleCheckBlocks(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Hashes []string `json:"hashes"`
	}
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	existing := s.store.CheckBlocks(req.Hashes)
	if existing == nil {
		existing = []string{}
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"existing": existing})
}

// handleCreateFileFromBlocks handles POST /api/files/from-blocks.
// Creates a file metadata entry from pre-uploaded blocks.
func (s *Server) handleCreateFileFromBlocks(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())

	var req struct {
		Filename string               `json:"filename"`
		ParentID string               `json:"parent_id"`
		FileHash string               `json:"file_hash"`
		Blocks   []storage.BlockEntry `json:"blocks"`
		MimeType string               `json:"mime_type"`
	}
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	if req.Filename == "" || req.FileHash == "" || len(req.Blocks) == 0 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "filename, file_hash, and blocks are required"})
		return
	}

	// Write the manifest (verifies all blocks exist)
	totalSize, err := s.store.CreateManifest(req.FileHash, req.Blocks)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}

	if req.MimeType == "" {
		req.MimeType = "application/octet-stream"
	}

	// Create file metadata
	f, err := s.db.CreateFile(req.ParentID, claims.UserID, req.Filename, false, totalSize, req.FileHash, req.MimeType)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not create file metadata"})
		return
	}

	// Create version record for history tracking
	_, _ = s.db.CreateVersion(f.ID, 1, req.FileHash, "", totalSize, claims.UserID)

	writeJSON(w, http.StatusCreated, toFileResponse(*f))
}
