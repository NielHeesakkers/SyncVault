package rest

import (
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

// computeBlockSignaturesFromReader computes block signatures by streaming from r,
// reading one deltaBlockSize block at a time. Memory usage is O(deltaBlockSize).
func computeBlockSignaturesFromReader(r io.Reader) ([]blockSignature, error) {
	var sigs []blockSignature
	buf := make([]byte, deltaBlockSize)
	index := 0
	for {
		n, err := io.ReadFull(r, buf)
		if n > 0 {
			block := buf[:n]
			sh := sha256.Sum256(block)
			sigs = append(sigs, blockSignature{
				Index:      index,
				WeakHash:   computeWeakHash(block),
				StrongHash: hex.EncodeToString(sh[:]),
			})
			index++
		}
		if err == io.EOF || err == io.ErrUnexpectedEOF {
			break
		}
		if err != nil {
			return nil, err
		}
	}
	return sigs, nil
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

	// Compute block signatures on-the-fly from stored content (streaming — O(blockSize) memory).
	pr, pw := io.Pipe()
	sigsCh := make(chan struct {
		sigs []blockSignature
		err  error
	}, 1)
	go func() {
		sigs, err := computeBlockSignaturesFromReader(pr)
		sigsCh <- struct {
			sigs []blockSignature
			err  error
		}{sigs, err}
	}()
	if err := s.store.GetDirect(f.ContentHash.String, pw); err != nil {
		pw.CloseWithError(err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not read file content"})
		return
	}
	pw.Close()
	sigResult := <-sigsCh
	if sigResult.err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not compute block signatures"})
		return
	}
	sigs := sigResult.sigs

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

	// The "data" part is backed by a temp file (multipart parser spills to disk beyond 32MB).
	// Using FormFile gives us a seekable reader so we can access new blocks by offset without
	// loading everything into memory.
	dataFile, _, err := r.FormFile("data")
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing data part"})
		return
	}
	defer dataFile.Close()

	// Build fast lookup for reuse + new blocks.
	reuseSet := make(map[int]bool, len(manifest.ReuseBlocks))
	for _, idx := range manifest.ReuseBlocks {
		if idx < 0 {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": fmt.Sprintf("invalid reuse block index: %d", idx)})
			return
		}
		reuseSet[idx] = true
	}
	newBlockMap := make(map[int]deltaNewBlock, len(manifest.NewBlocks))
	for _, nb := range manifest.NewBlocks {
		if nb.Index < 0 || nb.Offset < 0 {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": fmt.Sprintf("invalid new block entry: idx=%d off=%d", nb.Index, nb.Offset)})
			return
		}
		newBlockMap[nb.Index] = nb
	}

	// Determine total output blocks.
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
	// Sanity cap: 10 GB file / 256 KB = 40960 blocks max. Anything larger is malicious/buggy.
	if totalBlocks > 50_000 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "too many blocks"})
		return
	}

	// Stream reconstruction: pipe the assembled bytes straight to PutDirect.
	// Memory usage is O(deltaBlockSize) instead of O(fileSize).
	pr, pw := io.Pipe()
	errCh := make(chan error, 1)
	go func() {
		defer pw.Close()
		// Open the existing file once for streaming reuse-block extraction.
		existingPR, existingPW := io.Pipe()
		go func() {
			defer existingPW.Close()
			if err := s.store.GetDirect(f.ContentHash.String, existingPW); err != nil {
				existingPW.CloseWithError(err)
			}
		}()

		// Stream through existing file block-by-block, writing reused blocks to pw.
		// For new blocks, seek into dataFile.
		existingBuf := make([]byte, deltaBlockSize)
		existingIdx := 0
		existingEOF := false
		readExistingBlock := func() ([]byte, error) {
			if existingEOF {
				return nil, io.EOF
			}
			n, err := io.ReadFull(existingPR, existingBuf)
			if err == io.EOF || err == io.ErrUnexpectedEOF {
				existingEOF = true
				if n > 0 {
					return existingBuf[:n], nil
				}
				return nil, io.EOF
			}
			if err != nil {
				return nil, err
			}
			return existingBuf[:n], nil
		}

		dataSeeker, canSeek := dataFile.(io.ReadSeeker)
		newBuf := make([]byte, deltaBlockSize)

		for i := 0; i < totalBlocks; i++ {
			if reuseSet[i] {
				// Advance the existing-file reader to block i (sequential read).
				for existingIdx <= i {
					blk, rerr := readExistingBlock()
					if rerr != nil {
						pw.CloseWithError(fmt.Errorf("reuse block %d out of range: %w", i, rerr))
						return
					}
					if existingIdx == i {
						if _, werr := pw.Write(blk); werr != nil {
							return
						}
					}
					existingIdx++
				}
			} else if nb, ok := newBlockMap[i]; ok {
				if !canSeek {
					pw.CloseWithError(errors.New("data part is not seekable"))
					return
				}
				if _, serr := dataSeeker.Seek(nb.Offset, io.SeekStart); serr != nil {
					pw.CloseWithError(fmt.Errorf("seek to new block %d offset %d: %w", i, nb.Offset, serr))
					return
				}
				n, rerr := io.ReadFull(dataSeeker, newBuf)
				if rerr != nil && rerr != io.EOF && rerr != io.ErrUnexpectedEOF {
					pw.CloseWithError(fmt.Errorf("read new block %d: %w", i, rerr))
					return
				}
				if n == 0 {
					pw.CloseWithError(fmt.Errorf("new block %d offset %d is beyond data end", i, nb.Offset))
					return
				}
				if _, werr := pw.Write(newBuf[:n]); werr != nil {
					return
				}
			} else {
				pw.CloseWithError(fmt.Errorf("block %d is neither in reuse_blocks nor new_blocks", i))
				return
			}
		}
		errCh <- nil
	}()

	// Store streamed reconstruction. PutDirect hashes + writes atomically.
	contentHash, size, err := s.store.PutDirect(pr)
	if err != nil {
		pr.CloseWithError(err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not store reconstructed file: " + err.Error()})
		return
	}
	// Drain the reconstruction goroutine's error channel (if it managed to finish cleanly).
	select {
	case rerr := <-errCh:
		if rerr != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": rerr.Error()})
			return
		}
	default:
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

	// Compute and cache block signatures for the new version via streaming pipe
	// (avoids loading the reconstructed file into memory a second time).
	sigPR, sigPW := io.Pipe()
	sigCh := make(chan []blockSignature, 1)
	go func() {
		sigs, err := computeBlockSignaturesFromReader(sigPR)
		if err != nil {
			sigCh <- nil
			return
		}
		sigCh <- sigs
	}()
	if err := s.store.GetDirect(contentHash, sigPW); err != nil {
		sigPW.CloseWithError(err)
	} else {
		sigPW.Close()
	}
	if newSigs := <-sigCh; newSigs != nil {
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
