# SyncVault — Server Design Spec

> Open-source file sync and backup platform. Self-hosted alternative to Synology Drive.
> Docker backend (Go) + Web UI (SvelteKit) + macOS native client (Swift).

## Overview

SyncVault lets individuals and mid-sized teams sync, back up, and share files through a self-hosted server running in Docker. Users access their files through a native macOS app (with Finder integration and on-demand sync), a web browser, or both. An admin manages users, shared folders, permissions, retention policies, and storage quotas through a built-in web panel.

## Architecture

### Deployment

Single Docker container. One Go binary serves everything: gRPC sync API, REST API, and the embedded SvelteKit web UI.

```
docker run -d \
  -p 8080:8080 \
  -p 6690:6690 \
  -v /path/to/data:/data \
  syncvault/server
```

- Port **8080**: REST API + Web UI (HTTP or HTTPS)
- Port **6690**: gRPC sync protocol (TLS)
- Volume `/data`: all files, database, and configuration

Accessible directly via open port or behind a reverse proxy (nginx, Caddy, Traefik). Supports both HTTP and HTTPS — TLS can be handled by the server itself or by the reverse proxy.

### Server Internals (Modular Monolith)

Single binary, cleanly separated into independent Go packages:

| Package | Responsibility |
|---------|---------------|
| `api/grpc` | gRPC service for sync clients — file streaming, change events, backup protocol |
| `api/rest` | REST endpoints for web UI, file management, sharing, admin operations |
| `sync` | Sync engine: delta diffing, conflict resolution, selective sync rules |
| `versioning` | File version management, patch storage, version rotation policies |
| `auth` | JWT authentication, user management, permissions, session handling |
| `storage` | Content-addressable file store, chunk management, disk operations |
| `metadata` | SQLite database layer — file index, users, versions, sync state, activity log |
| `watcher` | Filesystem monitoring (fsnotify), change detection, event broadcasting to connected clients |
| `sharing` | Share link generation, password protection, expiration, download limits |

### Data Storage

- **Files**: Content-addressable store on local disk. Files are split into chunks and stored by hash. Deduplication is automatic — identical chunks across files/versions are stored once.
- **Metadata**: Single SQLite database (`/data/vault.db`) containing:
  - File index (paths, sizes, checksums, modification times)
  - User accounts and permissions
  - Version history and patches
  - Sync state per client
  - Activity log
  - Share links

### Communication Protocols

- **gRPC (port 6690)**: Used by the macOS sync client. Bidirectional streaming for real-time file change notifications. Protobuf-defined messages for type safety. Handles file upload/download, sync negotiation, and backup transfers.
- **REST (port 8080)**: Used by the web UI and external integrations. Standard JSON API for file CRUD, user management, version browsing, sharing, and admin operations.

## Features

### User Management

- Admin creates and manages user accounts via the web panel
- Two roles: **Admin** (full access, user management, settings) and **User** (access to own files and permitted team folders)
- Per-user storage quota with warnings at 80%, 90%, and 100%
- Password-based authentication with JWT tokens
- Connected devices overview — see which devices each user has linked

### Team Folders

- Admin creates shared folders (e.g., "Marketing", "Development", "Design Assets")
- Per-user permissions on each folder: **read-only** or **read-write**
- Every user also gets a private "My Files" space
- Team folder contents sync to permitted users' macOS apps

### File Sync

Two sync modes available to the macOS client:

**Two-way sync**: Changes propagate in both directions. Edit a file locally, it syncs to the server and other clients. Edit on another device, it syncs back.

**One-way backup**: Selected local folders are backed up to the server. Changes on the server do not flow back. Backup modes:
- **Continuous** — monitor and back up changes in real-time
- **Scheduled** — run at configured intervals (daily, weekly, specific times)
- **Manual** — back up on demand

### On-Demand Sync (macOS File Provider Extension)

Files appear in Finder but are not downloaded until opened. Implemented using Apple's File Provider framework (`NSFileProviderReplicatedExtension`), which requires macOS 12.3+ and APFS.

File states shown with Finder badges:
- **Cloud icon** — file is in the cloud, not downloaded locally
- **Checkmark** — downloaded and up to date
- **Sync arrows** — currently uploading or downloading

Context menu actions:
- **"Download Now"** — downloads the file and pins it locally. The file stays local until the user explicitly removes it.
- **"Remove Download"** — removes the local copy. The file remains visible in Finder with a cloud icon and will be re-downloaded when opened.

On-demand files appear in `~/Library/CloudStorage/SyncVault-{TaskName}/`.

### Delta Sync

When a file is modified, only the changed parts are transferred — not the entire file. The client compares blocks against the previous version and sends only the patches. This significantly reduces bandwidth usage, especially for large files.

### Selective Sync

Users can configure which folders to sync, and filter rules to exclude:
- Specific folder paths
- Filename patterns (glob matching, e.g., `*.tmp`, `node_modules`)
- Files exceeding a size limit

### Conflict Resolution

When the same file is modified on multiple devices before syncing:
- The most recent modification wins by default
- The losing version is saved as a conflict copy: `filename_devicename_timestamp.ext`
- Users can review and resolve conflicts through the macOS app or web UI

### File Versioning

- Up to **32 historical versions** per file (configurable per folder)
- Versions stored efficiently as **delta patches** — only the differences between versions are saved
- Browse version history in the web UI or macOS app
- Preview any version, download it, or restore it as the current version
- Two version rotation algorithms when the limit is reached:
  - **FIFO** (First-In-First-Out): oldest version is removed
  - **Intelliversioning**: keeps the most significant versions spread across time, discarding clustered versions that are close together

### Retention Policy

Automatic cleanup of old versions based on configurable rules:

| Tier | Default |
|------|---------|
| Daily versions | Keep for 7 days |
| Weekly versions | Keep for 4 weeks |
| Monthly versions | Keep for 6 months |
| Yearly versions | Keep forever |

- Configurable per folder — different policies for different data
- **Manual deletion**: delete specific versions or all versions of a file
- **Trash bin**: deleted files go to trash with a 30-day recovery period before permanent removal
- **"Clean up now"** action for immediate disk space reclamation

### Storage Insights

Dashboard showing:
- Total storage used vs. available
- Size per Team Folder
- Size per user (private files)
- How much space file versions occupy
- Quota usage warnings

### Sharing via Link

Generate download links for files or folders to share with people outside the team (no account needed):
- Optional password protection
- Configurable expiration date
- Download limit (max N downloads)
- Folders downloadable as .zip
- Links remain valid even if the file is moved or renamed within SyncVault

### Activity Log

Track who did what:
- File uploads, downloads, edits, deletions
- User logins and device connections
- Permission changes
- Share link creation and access
- Filterable by user, date range, and action type

### Security

- TLS encryption for all data in transit (self-managed or via reverse proxy)
- JWT token-based authentication
- Password hashing (bcrypt)
- Per-folder access control
- Share links with password protection and expiration
- Activity logging for audit purposes

## Build Order

Each subsystem gets its own spec → plan → implementation cycle:

1. **Server core** — storage engine, metadata database, versioning, auth, gRPC + REST API, Docker setup
2. **Web Interface** — file browser, version history, admin panel, sharing, storage insights
3. **macOS App** — sync client, backup, settings UI
4. **On-demand sync** — File Provider Extension, Finder integration, context menu actions

## Technology Stack

| Component | Technology |
|-----------|-----------|
| Server | Go (modular monolith) |
| Web UI | SvelteKit (embedded in server binary) |
| macOS App | Swift + SwiftUI |
| Sync Protocol | gRPC with bidirectional streaming (protobuf) |
| REST API | Go standard library + chi router |
| Database | SQLite (via modernc.org/sqlite, pure Go) |
| File Storage | Content-addressable store with chunking |
| Versioning | Delta patches (binary diff) |
| Auth | JWT (access + refresh tokens) |
| macOS Integration | File Provider framework (NSFileProviderReplicatedExtension) |
| Containerization | Docker (single container) |

## Out of Scope (for now)

- Mobile apps (iOS, Android)
- LDAP / Active Directory integration
- Remote wipe of client devices
- End-to-end encryption
- Multi-server / cluster deployment
- Upload links (file requests from externals)
- Real-time collaborative editing (Synology Office equivalent)
