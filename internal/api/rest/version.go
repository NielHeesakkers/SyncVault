package rest

import (
	_ "embed"
	"net/http"
	"strings"
)

//go:embed changelog.txt
var changelogData string

// handleVersion returns the current version and changelog.
func (s *Server) handleVersion(w http.ResponseWriter, r *http.Request) {
	// Parse changelog into structured format
	versions := parseChangelog(changelogData)
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"current_version": AppVersion,
		"changelog":       versions,
	})
}

type ChangelogVersion struct {
	Version string   `json:"version"`
	Date    string   `json:"date"`
	Changes []string `json:"changes"`
}

func parseChangelog(raw string) []ChangelogVersion {
	var versions []ChangelogVersion
	var current *ChangelogVersion

	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "## [") {
			// New version header: ## [1.0] — 2026-03-21
			if current != nil {
				versions = append(versions, *current)
			}
			parts := strings.SplitN(line, " — ", 2)
			version := strings.TrimPrefix(parts[0], "## [")
			version = strings.TrimSuffix(version, "]")
			date := ""
			if len(parts) > 1 {
				date = parts[1]
			}
			current = &ChangelogVersion{Version: version, Date: date}
		} else if strings.HasPrefix(line, "- ") && current != nil {
			current.Changes = append(current.Changes, strings.TrimPrefix(line, "- "))
		}
	}
	if current != nil {
		versions = append(versions, *current)
	}
	return versions
}
