package rest

import (
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"path/filepath"
	"strconv"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
	"github.com/NielHeesakkers/SyncVault/internal/metadata"
	"github.com/go-chi/chi/v5"
)

const (
	// defaultChunkSize is 64 MiB.
	defaultChunkSize int64 = 64 << 20
	// maxChunkSize is 256 MiB.
	maxChunkSize int64 = 256 << 20
)

// uploadDir returns the directory used to stage chunks for the given upload ID.
func (s *Server) uploadDir(uploadID string) string {
	return filepath.Join(s.uploadsDir, uploadID)
}

// chunkPath returns the file path for chunk n of the given upload.
func (s *Server) chunkPath(uploadID string, n int) string {
	return filepath.Join(s.uploadDir(uploadID), fmt.Sprintf("chunk_%d", n))
}

// initUploadRequest is the body for POST /api/uploads/init.
type initUploadRequest struct {
	Filename   string `json:"filename"`
	ParentID   string `json:"parent_id"`
	TotalSize  int64  `json:"total_size"`
	ChunkSize  int64  `json:"chunk_size"`
}

// initUploadResponse is returned by POST /api/uploads/init.
type initUploadResponse struct {
	UploadID    string `json:"upload_id"`
	ChunkSize   int64  `json:"chunk_size"`
	TotalChunks int    `json:"total_chunks"`
}

// handleInitUpload handles POST /api/uploads/init.
func (s *Server) handleInitUpload(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())

	var req initUploadRequest
	if err := readJSON(r, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}
	if req.Filename == "" || req.TotalSize <= 0 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "filename and total_size are required"})
		return
	}

	chunkSize := req.ChunkSize
	if chunkSize <= 0 {
		chunkSize = defaultChunkSize
	}
	if chunkSize > maxChunkSize {
		chunkSize = maxChunkSize
	}

	totalChunks := int(math.Ceil(float64(req.TotalSize) / float64(chunkSize)))

	sess, err := s.db.CreateUploadSession(claims.UserID, req.ParentID, req.Filename, req.TotalSize, chunkSize, totalChunks)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not create upload session"})
		return
	}

	// Pre-create the staging directory.
	if err := os.MkdirAll(s.uploadDir(sess.ID), 0755); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not create upload staging directory"})
		return
	}

	writeJSON(w, http.StatusCreated, initUploadResponse{
		UploadID:    sess.ID,
		ChunkSize:   chunkSize,
		TotalChunks: totalChunks,
	})
}

// handleUploadChunk handles PUT /api/uploads/{id}/chunks/{n}.
func (s *Server) handleUploadChunk(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	uploadID := chi.URLParam(r, "id")
	nStr := chi.URLParam(r, "n")

	n, err := strconv.Atoi(nStr)
	if err != nil || n < 0 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid chunk number"})
		return
	}

	sess, err := s.db.GetUploadSession(uploadID)
	if err != nil {
		if errors.Is(err, metadata.ErrUploadNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "upload session not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get upload session"})
		return
	}

	if sess.UserID != claims.UserID {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "forbidden"})
		return
	}

	if n >= sess.TotalChunks {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "chunk number out of range"})
		return
	}

	// Write chunk data to a temp file.
	cp := s.chunkPath(uploadID, n)
	if err := os.MkdirAll(filepath.Dir(cp), 0755); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not create chunk directory"})
		return
	}

	f, err := os.Create(cp)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not create chunk file"})
		return
	}
	defer f.Close()

	if _, err := io.Copy(f, r.Body); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not write chunk data"})
		return
	}

	if _, err := s.db.AddReceivedChunk(uploadID, n); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not record chunk"})
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"chunk":    n,
		"received": true,
	})
}

// uploadStatusResponse is returned by GET /api/uploads/{id}/status.
type uploadStatusResponse struct {
	UploadID       string `json:"upload_id"`
	Filename       string `json:"filename"`
	TotalChunks    int    `json:"total_chunks"`
	ReceivedChunks []int  `json:"received_chunks"`
	Complete       bool   `json:"complete"`
}

// handleUploadStatus handles GET /api/uploads/{id}/status.
func (s *Server) handleUploadStatus(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	uploadID := chi.URLParam(r, "id")

	sess, err := s.db.GetUploadSession(uploadID)
	if err != nil {
		if errors.Is(err, metadata.ErrUploadNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "upload session not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get upload session"})
		return
	}

	if sess.UserID != claims.UserID {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "forbidden"})
		return
	}

	chunks := sess.ReceivedChunks
	if chunks == nil {
		chunks = []int{}
	}

	writeJSON(w, http.StatusOK, uploadStatusResponse{
		UploadID:       sess.ID,
		Filename:       sess.Filename,
		TotalChunks:    sess.TotalChunks,
		ReceivedChunks: chunks,
		Complete:       len(chunks) == sess.TotalChunks,
	})
}

// handleCompleteUpload handles POST /api/uploads/{id}/complete.
// It assembles all chunks, stores the result via storage.Put, creates a file record, and cleans up temp files.
func (s *Server) handleCompleteUpload(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	uploadID := chi.URLParam(r, "id")

	sess, err := s.db.GetUploadSession(uploadID)
	if err != nil {
		if errors.Is(err, metadata.ErrUploadNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "upload session not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get upload session"})
		return
	}

	if sess.UserID != claims.UserID {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "forbidden"})
		return
	}

	// Check all chunks are present.
	if len(sess.ReceivedChunks) != sess.TotalChunks {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": fmt.Sprintf("not all chunks received: got %d of %d", len(sess.ReceivedChunks), sess.TotalChunks),
		})
		return
	}

	// Assemble chunks into a single reader.
	pr, pw := io.Pipe()

	go func() {
		for i := 0; i < sess.TotalChunks; i++ {
			cp := s.chunkPath(uploadID, i)
			f, err := os.Open(cp)
			if err != nil {
				pw.CloseWithError(fmt.Errorf("could not open chunk %d: %w", i, err))
				return
			}
			if _, err := io.Copy(pw, f); err != nil {
				f.Close()
				pw.CloseWithError(fmt.Errorf("could not read chunk %d: %w", i, err))
				return
			}
			f.Close()
		}
		pw.Close()
	}()

	contentHash, size, err := s.store.Put(pr)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not store assembled file"})
		return
	}

	// Detect MIME type from the first chunk.
	mimeType := "application/octet-stream"
	if cp0 := s.chunkPath(uploadID, 0); func() bool {
		f, err := os.Open(cp0)
		if err != nil {
			return false
		}
		defer f.Close()
		buf := make([]byte, 512)
		n, _ := f.Read(buf)
		mimeType = http.DetectContentType(buf[:n])
		return true
	}() {
	}

	parentID := ""
	if sess.ParentID.Valid {
		parentID = sess.ParentID.String
	}

	// Create file metadata entry.
	f, err := s.db.CreateFile(parentID, claims.UserID, sess.Filename, false, size, contentHash, mimeType)
	if err != nil {
		if errors.Is(err, metadata.ErrDuplicateFile) {
			writeJSON(w, http.StatusConflict, map[string]string{"error": "file already exists"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not create file metadata"})
		return
	}

	// Create version 1.
	if _, err := s.db.CreateVersion(f.ID, 1, contentHash, "", size, claims.UserID); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not create version"})
		return
	}

	// Clean up staging directory.
	_ = os.RemoveAll(s.uploadDir(uploadID))

	// Remove the session record.
	_ = s.db.DeleteUploadSession(uploadID)

	writeJSON(w, http.StatusCreated, map[string]interface{}{
		"id":           f.ID,
		"name":         f.Name,
		"size":         f.Size,
		"content_hash": contentHash,
	})
}
