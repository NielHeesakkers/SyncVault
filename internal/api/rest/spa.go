package rest

import (
	"embed"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

//go:embed all:dist
var spaFiles embed.FS

// ServeSPA returns an http.Handler that serves the embedded SvelteKit SPA.
// It tries to serve static files first, then falls back to index.html for SPA routing.
// Static assets get long-lived cache headers; HTML gets short cache for fast updates.
func ServeSPA() http.Handler {
	distFS, err := fs.Sub(spaFiles, "dist")
	if err != nil {
		panic("failed to create sub filesystem: " + err.Error())
	}
	fileServer := http.FileServer(http.FS(distFS))

	// Pre-read index.html once at startup (it's small, ~1-2 KB)
	indexContent, _ := fs.ReadFile(distFS, "index.html")
	indexFile, _ := distFS.Open("index.html")
	var indexModTime = func() int64 {
		if indexFile != nil {
			if stat, err := indexFile.Stat(); err == nil {
				return stat.ModTime().Unix()
			}
		}
		return 0
	}()
	if indexFile != nil {
		indexFile.Close()
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := strings.TrimPrefix(r.URL.Path, "/")
		if path == "" {
			path = "index.html"
		}

		// Try to open the file
		f, err := distFS.Open(path)
		if err == nil {
			f.Close()
			// Set cache headers based on file type
			setCacheHeaders(w, path)
			fileServer.ServeHTTP(w, r)
			return
		}

		// SPA fallback: serve pre-loaded index.html
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		_ = indexModTime
		w.Write(indexContent)
	})
}

// setCacheHeaders sets appropriate Cache-Control headers based on file extension.
// SvelteKit hashed assets (_app/immutable/) get 1 year cache; other assets 24 hours.
func setCacheHeaders(w http.ResponseWriter, path string) {
	if strings.Contains(path, "_app/immutable/") {
		// Hashed filenames — cache forever (content changes = new filename)
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		return
	}
	switch {
	case strings.HasSuffix(path, ".js"), strings.HasSuffix(path, ".css"):
		w.Header().Set("Cache-Control", "public, max-age=86400") // 24h
	case strings.HasSuffix(path, ".html"):
		w.Header().Set("Cache-Control", "no-cache") // Always revalidate
	case strings.HasSuffix(path, ".png"), strings.HasSuffix(path, ".svg"),
		strings.HasSuffix(path, ".ico"), strings.HasSuffix(path, ".woff2"):
		w.Header().Set("Cache-Control", "public, max-age=604800") // 7 days
	default:
		w.Header().Set("Cache-Control", "public, max-age=3600") // 1h
	}
}

// ServeSPAFromDir serves the SPA from a directory on disk (for development).
func ServeSPAFromDir(dir string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := filepath.Join(dir, strings.TrimPrefix(r.URL.Path, "/"))
		if _, err := os.Stat(path); err == nil {
			http.FileServer(http.Dir(dir)).ServeHTTP(w, r)
			return
		}
		http.ServeFile(w, r, filepath.Join(dir, "index.html"))
	})
}
