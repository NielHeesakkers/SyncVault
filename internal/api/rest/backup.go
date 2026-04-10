package rest

import (
	"archive/zip"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
)

type backupEntry struct {
	Name      string `json:"name"`
	Size      int64  `json:"size"`
	CreatedAt string `json:"created_at"`
}

func (s *Server) backupDir() string {
	dataDir := os.Getenv("SYNCVAULT_DATA_DIR")
	if dataDir == "" {
		dataDir = "data"
	}
	dir := filepath.Join(dataDir, "backups")
	os.MkdirAll(dir, 0755)
	return dir
}

// handleListBackups handles GET /api/admin/backups.
func (s *Server) handleListBackups(w http.ResponseWriter, r *http.Request) {
	dir := s.backupDir()
	entries, err := os.ReadDir(dir)
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]interface{}{"backups": []backupEntry{}})
		return
	}

	var backups []backupEntry
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".zip") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		backups = append(backups, backupEntry{
			Name:      e.Name(),
			Size:      info.Size(),
			CreatedAt: info.ModTime().UTC().Format(time.RFC3339),
		})
	}

	// Sort newest first
	sort.Slice(backups, func(i, j int) bool {
		return backups[i].CreatedAt > backups[j].CreatedAt
	})

	writeJSON(w, http.StatusOK, map[string]interface{}{"backups": backups})
}

// handleCreateBackup handles POST /api/admin/backups.
// Creates a ZIP backup of the database and settings.
func (s *Server) handleCreateBackup(w http.ResponseWriter, r *http.Request) {
	dataDir := os.Getenv("SYNCVAULT_DATA_DIR")
	if dataDir == "" {
		dataDir = "data"
	}

	timestamp := time.Now().UTC().Format("2006-01-02_150405")
	backupName := fmt.Sprintf("syncvault-backup-%s.zip", timestamp)
	backupPath := filepath.Join(s.backupDir(), backupName)

	zipFile, err := os.Create(backupPath)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not create backup file"})
		return
	}
	defer zipFile.Close()

	zw := zip.NewWriter(zipFile)
	defer zw.Close()

	// Backup the database
	dbFiles := []string{"syncvault.db", "vault.db"}
	for _, dbName := range dbFiles {
		dbPath := filepath.Join(dataDir, dbName)
		if _, err := os.Stat(dbPath); err == nil {
			if err := addFileToZip(zw, dbPath, dbName); err != nil {
				writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not add database to backup"})
				return
			}
		}
	}

	info, _ := os.Stat(backupPath)
	size := int64(0)
	if info != nil {
		size = info.Size()
	}

	writeJSON(w, http.StatusCreated, backupEntry{
		Name:      backupName,
		Size:      size,
		CreatedAt: time.Now().UTC().Format(time.RFC3339),
	})
}

// handleDownloadBackup handles GET /api/admin/backups/{name}/download.
func (s *Server) handleDownloadBackup(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if strings.Contains(name, "..") || strings.Contains(name, "/") {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid backup name"})
		return
	}

	path := filepath.Join(s.backupDir(), name)
	if _, err := os.Stat(path); os.IsNotExist(err) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "backup not found"})
		return
	}

	file, err := os.Open(path)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not open backup"})
		return
	}
	defer file.Close()

	info, _ := file.Stat()
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, name))
	w.Header().Set("Content-Length", fmt.Sprintf("%d", info.Size()))
	io.Copy(w, file)
}

// handleDeleteBackup handles DELETE /api/admin/backups/{name}.
func (s *Server) handleDeleteBackup(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if strings.Contains(name, "..") || strings.Contains(name, "/") {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid backup name"})
		return
	}

	path := filepath.Join(s.backupDir(), name)
	if err := os.Remove(path); err != nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "backup not found"})
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

// handleRestoreBackup handles POST /api/admin/backups/{name}/restore.
func (s *Server) handleRestoreBackup(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if strings.Contains(name, "..") || strings.Contains(name, "/") {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid backup name"})
		return
	}

	backupPath := filepath.Join(s.backupDir(), name)
	if _, err := os.Stat(backupPath); os.IsNotExist(err) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "backup not found"})
		return
	}

	dataDir := os.Getenv("SYNCVAULT_DATA_DIR")
	if dataDir == "" {
		dataDir = "data"
	}

	// Extract ZIP
	zr, err := zip.OpenReader(backupPath)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not read backup"})
		return
	}
	defer zr.Close()

	absDataDir, _ := filepath.Abs(dataDir)
	for _, f := range zr.File {
		targetPath := filepath.Join(dataDir, f.Name)
		// Path traversal protection: resolve the full path and verify it stays within dataDir.
		absTarget, _ := filepath.Abs(targetPath)
		if !strings.HasPrefix(absTarget, absDataDir+string(os.PathSeparator)) && absTarget != absDataDir {
			continue
		}
		if f.FileInfo().IsDir() {
			continue
		}

		rc, err := f.Open()
		if err != nil {
			continue
		}

		outFile, err := os.Create(absTarget)
		if err != nil {
			rc.Close()
			continue
		}

		io.Copy(outFile, rc)
		outFile.Close()
		rc.Close()
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "restored"})
}

// handleUploadRestore handles POST /api/admin/backups/upload.
// Accepts a ZIP file upload and restores it.
func (s *Server) handleUploadRestore(w http.ResponseWriter, r *http.Request) {
	r.ParseMultipartForm(100 << 20) // 100MB max
	file, header, err := r.FormFile("file")
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "no file uploaded"})
		return
	}
	defer file.Close()

	// Save to backups dir first
	name := header.Filename
	if name == "" {
		name = fmt.Sprintf("uploaded-%s.zip", time.Now().UTC().Format("2006-01-02_150405"))
	}
	// Sanitize uploaded filename to prevent path traversal.
	name = filepath.Base(name)
	backupPath := filepath.Join(s.backupDir(), name)
	outFile, err := os.Create(backupPath)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "could not save file"})
		return
	}
	io.Copy(outFile, file)
	outFile.Close()

	// Now restore from it
	dataDir := os.Getenv("SYNCVAULT_DATA_DIR")
	if dataDir == "" {
		dataDir = "data"
	}

	zr, err := zip.OpenReader(backupPath)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid ZIP file"})
		return
	}
	defer zr.Close()

	absDataDir, _ := filepath.Abs(dataDir)
	for _, f := range zr.File {
		targetPath := filepath.Join(dataDir, f.Name)
		absTarget, _ := filepath.Abs(targetPath)
		if !strings.HasPrefix(absTarget, absDataDir+string(os.PathSeparator)) && absTarget != absDataDir {
			continue
		}
		if f.FileInfo().IsDir() {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			continue
		}
		out, err := os.Create(absTarget)
		if err != nil {
			rc.Close()
			continue
		}
		io.Copy(out, rc)
		out.Close()
		rc.Close()
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "restored"})
}

func addFileToZip(zw *zip.Writer, filePath, zipName string) error {
	file, err := os.Open(filePath)
	if err != nil {
		return err
	}
	defer file.Close()

	w, err := zw.Create(zipName)
	if err != nil {
		return err
	}

	_, err = io.Copy(w, file)
	return err
}
