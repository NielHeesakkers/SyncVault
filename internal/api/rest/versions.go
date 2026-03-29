package rest

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/NielHeesakkers/SyncVault/internal/metadata"
	"github.com/go-chi/chi/v5"
)

// versionResponse is the JSON representation of a file version.
type versionResponse struct {
	ID          string    `json:"id"`
	FileID      string    `json:"file_id"`
	VersionNum  int       `json:"version_num"`
	ContentHash string    `json:"content_hash"`
	Size        int64     `json:"size"`
	CreatedBy   string    `json:"created_by"`
	CreatedAt   time.Time `json:"created_at"`
}

func toVersionResponse(v metadata.Version) versionResponse {
	return versionResponse{
		ID:          v.ID,
		FileID:      v.FileID,
		VersionNum:  v.VersionNum,
		ContentHash: v.ContentHash,
		Size:        v.Size,
		CreatedBy:   v.CreatedBy,
		CreatedAt:   v.CreatedAt,
	}
}

// handleListVersions handles GET /api/files/{id}/versions.
func (s *Server) handleListVersions(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	if _, ok := s.checkFileOwnership(w, r, id); !ok {
		return
	}

	versions, err := s.db.ListVersions(id)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not list versions"})
		return
	}

	result := make([]versionResponse, 0, len(versions))
	for _, v := range versions {
		result = append(result, toVersionResponse(v))
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"versions": result})
}

// handleDownloadVersion handles GET /api/files/{id}/versions/{versionNum}/download.
func (s *Server) handleDownloadVersion(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	versionNumStr := chi.URLParam(r, "versionNum")

	versionNum, err := strconv.Atoi(versionNumStr)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid version number"})
		return
	}

	f, ok := s.checkFileOwnership(w, r, id)
	if !ok {
		return
	}

	v, err := s.db.GetVersionByNum(id, versionNum)
	if err != nil {
		if errors.Is(err, metadata.ErrVersionNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "version not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get version"})
		return
	}

	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, sanitizeFilename(f.Name)))

	if err := s.store.Get(v.ContentHash, w); err != nil {
		// Headers already sent; nothing to do.
		return
	}
}

// handleRestoreVersion handles POST /api/files/{id}/versions/{versionNum}/restore.
func (s *Server) handleRestoreVersion(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	versionNumStr := chi.URLParam(r, "versionNum")

	versionNum, err := strconv.Atoi(versionNumStr)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid version number"})
		return
	}

	if _, ok := s.checkFileOwnership(w, r, id); !ok {
		return
	}

	v, err := s.db.GetVersionByNum(id, versionNum)
	if err != nil {
		if errors.Is(err, metadata.ErrVersionNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "version not found"})
			return
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not get version"})
		return
	}

	if err := s.db.UpdateFileContent(id, v.ContentHash, v.Size); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not restore version"})
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "restored"})
}
