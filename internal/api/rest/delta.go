package rest

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"

	"github.com/NielHeesakkers/SyncVault/internal/auth"
	"github.com/NielHeesakkers/SyncVault/internal/metadata"
	"github.com/go-chi/chi/v5"
)

// deltaBlockSize is the size of each block used for delta sync (256 KiB).
const deltaBlockSize = 256 << 10

// blockSignature holds the weak (rolling) and strong (SHA-256) hashes of a single block.
type blockSignature struct {
	Index      int    `json:"index"`
	WeakHash   uint32 `json:"weak_hash"`
	StrongHash string `json:"strong_hash"`
}

// blocksResponse is returned by GET /api/files/{id}/blocks.
type blocksResponse struct {
	FileID    string           `json:"file_id"`
	BlockSize int              `json:"block_size"`
	Blocks    []blockSignature `json:"blocks"`
}

// computeWeakHash computes an Adler-32-style rolling hash over data.
func computeWeakHash(data []byte) uint32 {
	var a, b uint32
	const mod = 65521
	for _, v := range data {
		a = (a + uint32(v)) % mod
		b = (b + a) % mod
	}
	return (b << 16) | a
}

// computeBlockSignatures divides data into deltaBlockSize blocks and returns their signatures.
func computeBlockSignatures(data []byte) []blockSignature {
	var sigs []blockSignature
	for i := 0; i < len(data); i += deltaBlockSize {
		end := i + deltaBlockSize
		if end > len(data) {
			end = len(data)
		}
		block := data[i:end]
		sh := sha256.Sum256(block)
		sigs = append(sigs, blockSignature{
			Index:      i / deltaBlockSize,
			WeakHash:   computeWeakHash(block),
			StrongHash: hex.EncodeToString(sh[:]),
		})
	}
	return sigs
}

// handleGetBlocks handles GET /api/files/{id}/blocks.
// Returns the block signatures for the latest version of the file.
func (s *Server) handleGetBlocks(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	f, err := s.db.GetFileByID(id)
	if err != nil {
		if errors.Is(err, metadata.ErrFileNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "file not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get file"})
		return
	}

	if !f.ContentHash.Valid || f.ContentHash.String == "" {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]string{"error": "file has no content"})
		return
	}

	// Try to load cached block signatures from the DB.
	latestVersion, err := s.db.GetLatestVersion(id)
	if err != nil && !errors.Is(err, metadata.ErrVersionNotFound) {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get version"})
		return
	}

	var versionNum int
	if latestVersion != nil {
		versionNum = latestVersion.VersionNum
	}

	cachedBlocks, err := s.db.GetFileBlocks(id, versionNum)
	if err == nil && len(cachedBlocks) > 0 {
		sigs := make([]blockSignature, len(cachedBlocks))
		for i, b := range cachedBlocks {
			sigs[i] = blockSignature{
				Index:      b.BlockIndex,
				WeakHash:   b.WeakHash,
				StrongHash: b.StrongHash,
			}
		}
		writeJSON(w, http.StatusOK, blocksResponse{
			FileID:    id,
			BlockSize: deltaBlockSize,
			Blocks:    sigs,
		})
		return
	}

	// Compute block signatures on-the-fly from stored content.
	var buf bytes.Buffer
	if err := s.store.Get(f.ContentHash.String, &buf); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not read file content"})
		return
	}

	sigs := computeBlockSignatures(buf.Bytes())

	// Cache the signatures.
	dbBlocks := make([]metadata.FileBlock, len(sigs))
	for i, sig := range sigs {
		dbBlocks[i] = metadata.FileBlock{
			FileID:     id,
			VersionNum: versionNum,
			BlockIndex: sig.Index,
			WeakHash:   sig.WeakHash,
			StrongHash: sig.StrongHash,
		}
	}
	_ = s.db.SaveFileBlocks(dbBlocks)

	if sigs == nil {
		sigs = []blockSignature{}
	}

	writeJSON(w, http.StatusOK, blocksResponse{
		FileID:    id,
		BlockSize: deltaBlockSize,
		Blocks:    sigs,
	})
}

// deltaManifest describes which blocks to reuse from the existing file and where new blocks live.
type deltaManifest struct {
	ReuseBlocks []int         `json:"reuse_blocks"`
	NewBlocks   []deltaNewBlock `json:"new_blocks"`
}

// deltaNewBlock maps a destination block index to its byte offset within the "data" part.
type deltaNewBlock struct {
	Index  int   `json:"index"`
	Offset int64 `json:"offset"`
}

// handleDeltaUpload handles POST /api/files/{id}/delta.
// Accepts a multipart body with a "manifest" JSON part and a "data" binary part.
func (s *Server) handleDeltaUpload(w http.ResponseWriter, r *http.Request) {
	claims := auth.GetClaims(r.Context())
	id := chi.URLParam(r, "id")

	f, err := s.db.GetFileByID(id)
	if err != nil {
		if errors.Is(err, metadata.ErrFileNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "file not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get file"})
		return
	}

	if !f.ContentHash.Valid || f.ContentHash.String == "" {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]string{"error": "file has no content to delta against"})
		return
	}

	// Parse the multipart body.
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "could not parse multipart form"})
		return
	}

	manifestStr := r.FormValue("manifest")
	if manifestStr == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing manifest part"})
		return
	}

	var manifest deltaManifest
	if err := json.Unmarshal([]byte(manifestStr), &manifest); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid manifest JSON"})
		return
	}

	// Read the new block data.
	dataFile, _, err := r.FormFile("data")
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing data part"})
		return
	}
	defer dataFile.Close()

	newData, err := io.ReadAll(dataFile)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not read new block data"})
		return
	}

	// Read the existing file into memory.
	var existingBuf bytes.Buffer
	if err := s.store.Get(f.ContentHash.String, &existingBuf); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not read existing file content"})
		return
	}
	existing := existingBuf.Bytes()

	// Build an index of reuse blocks for fast lookup.
	reuseSet := make(map[int]bool, len(manifest.ReuseBlocks))
	for _, idx := range manifest.ReuseBlocks {
		reuseSet[idx] = true
	}

	// Build new block lookup by index.
	newBlockMap := make(map[int]deltaNewBlock, len(manifest.NewBlocks))
	for _, nb := range manifest.NewBlocks {
		newBlockMap[nb.Index] = nb
	}

	// Determine the total number of output blocks.
	totalBlocks := 0
	for idx := range reuseSet {
		if idx+1 > totalBlocks {
			totalBlocks = idx + 1
		}
	}
	for idx := range newBlockMap {
		if idx+1 > totalBlocks {
			totalBlocks = idx + 1
		}
	}

	// Reconstruct the new file.
	var reconstructed bytes.Buffer
	for i := 0; i < totalBlocks; i++ {
		if reuseSet[i] {
			// Copy from existing file.
			start := i * deltaBlockSize
			end := start + deltaBlockSize
			if start >= len(existing) {
				writeJSON(w, http.StatusBadRequest, map[string]string{
					"error": fmt.Sprintf("reuse block %d is out of range of existing file", i),
				})
				return
			}
			if end > len(existing) {
				end = len(existing)
			}
			reconstructed.Write(existing[start:end])
		} else if nb, ok := newBlockMap[i]; ok {
			// Copy from new data at offset.
			start := nb.Offset
			end := start + int64(deltaBlockSize)
			if start > int64(len(newData)) {
				writeJSON(w, http.StatusBadRequest, map[string]string{
					"error": fmt.Sprintf("new block %d offset %d is out of range of data", i, start),
				})
				return
			}
			if end > int64(len(newData)) {
				end = int64(len(newData))
			}
			reconstructed.Write(newData[start:end])
		} else {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": fmt.Sprintf("block %d is neither in reuse_blocks nor new_blocks", i),
			})
			return
		}
	}

	// Store the reconstructed file.
	contentHash, size, err := s.store.Put(&reconstructed)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not store reconstructed file"})
		return
	}

	// Update file metadata.
	if err := s.db.UpdateFileContent(id, contentHash, size); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not update file metadata"})
		return
	}

	// Create a new version record.
	latestVersion, _ := s.db.GetLatestVersion(id)
	nextVersionNum := 1
	if latestVersion != nil {
		nextVersionNum = latestVersion.VersionNum + 1
	}
	if _, err := s.db.CreateVersion(id, nextVersionNum, contentHash, "", size, claims.UserID); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not create version"})
		return
	}

	// Compute and cache block signatures for the new version.
	var newContentBuf bytes.Buffer
	if err := s.store.Get(contentHash, &newContentBuf); err == nil {
		newSigs := computeBlockSignatures(newContentBuf.Bytes())
		dbBlocks := make([]metadata.FileBlock, len(newSigs))
		for i, sig := range newSigs {
			dbBlocks[i] = metadata.FileBlock{
				FileID:     id,
				VersionNum: nextVersionNum,
				BlockIndex: sig.Index,
				WeakHash:   sig.WeakHash,
				StrongHash: sig.StrongHash,
			}
		}
		_ = s.db.SaveFileBlocks(dbBlocks)
	}

	updatedFile, err := s.db.GetFileByID(id)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get updated file"})
		return
	}
	writeJSON(w, http.StatusOK, toFileResponse(*updatedFile))
}
