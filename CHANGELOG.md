# Changelog

All notable changes to SyncVault will be documented in this file.

## [1.0] — 2026-03-21

### Added
- Content-addressable file storage with chunking and deduplication
- SQLite metadata database for users, files, versions, teams, shares, activity
- JWT authentication with bcrypt password hashing
- Role-based access control (admin / user)
- File versioning with delta patches (up to 32 versions per file)
- FIFO and Intelliversioning rotation algorithms
- Retention policies (daily/weekly/monthly/yearly tiers)
- REST API with 30+ endpoints
- SvelteKit web interface with:
  - File browser with upload, download, folder creation
  - Version history with restore and download
  - Share links with password, expiration, download limits
  - Trash with restore and permanent delete
  - Admin panel: Users, Teams, Storage, Activity Log, SMTP Settings
  - Password change with double confirmation
- macOS menu bar sync client with:
  - Two-way sync and one-way backup
  - REST API client with Keychain auth storage
  - Sync engine with FSEvents file monitoring
  - Sparkle auto-update framework
  - Settings UI (connection, sync tasks, general)
- SMTP email notifications (welcome, password reset, quota warnings)
- Change feed endpoint for efficient sync polling
- Docker deployment (single container, multi-arch)
- GitHub Actions CI/CD (Docker image + macOS DMG build)
- Portainer-ready docker-compose file
