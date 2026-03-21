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
func ServeSPA() http.Handler {
	distFS, err := fs.Sub(spaFiles, "dist")
	if err != nil {
		panic("failed to create sub filesystem: " + err.Error())
	}
	fileServer := http.FileServer(http.FS(distFS))

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := strings.TrimPrefix(r.URL.Path, "/")
		if path == "" {
			path = "index.html"
		}

		// Try to open the file
		f, err := distFS.Open(path)
		if err == nil {
			f.Close()
			fileServer.ServeHTTP(w, r)
			return
		}

		// If file not found, serve index.html (SPA fallback)
		indexFile, err := distFS.Open("index.html")
		if err != nil {
			http.NotFound(w, r)
			return
		}
		defer indexFile.Close()

		stat, _ := indexFile.Stat()
		content, _ := fs.ReadFile(distFS, "index.html")
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		http.ServeContent(w, r, "index.html", stat.ModTime(), strings.NewReader(string(content)))
	})
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
