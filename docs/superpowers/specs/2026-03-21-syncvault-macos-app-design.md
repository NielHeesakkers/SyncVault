# SyncVault macOS App — Design Spec

> Phase 3: Native macOS sync client with menu bar integration.

## Overview

A native macOS app that connects to a SyncVault server and provides two-way file sync, one-way backup, and a menu bar interface for monitoring sync status. Built with Swift and SwiftUI. Communicates with the server via the REST API (gRPC deferred to a later phase).

## Architecture

### App Structure

- **Menu bar app** (no dock icon by default) with a popover showing sync status
- **Settings window** for server connection, sync tasks, and backup configuration
- **Background sync service** that runs continuously
- Distributed as a `.dmg` installer, signed and notarized with Apple Developer account

### Communication

Uses the existing REST API (not gRPC for now — simpler to implement, sufficient for initial release):
- `POST /api/auth/login` — authenticate
- `GET /api/files?parent_id=...` — list remote files
- `POST /api/files/upload` — upload files
- `GET /api/files/{id}/download` — download files
- `GET /api/files/{id}/versions` — version history
- `PUT /api/files/{id}` — rename/move
- `DELETE /api/files/{id}` — delete

### Local Storage

- `~/Library/Application Support/SyncVault/` — app data
  - `config.json` — server URL, credentials (stored in Keychain), sync task definitions
  - `sync.db` — SQLite database tracking local file state (path, hash, modified time, sync status)
  - `logs/` — sync operation logs

## Features

### 1. Menu Bar Icon

- Cloud icon in the menu bar
- States: idle (cloud), syncing (cloud with arrows), error (cloud with exclamation)
- Click opens a popover with:
  - Server connection status (connected/disconnected)
  - Current sync activity ("Syncing 3 files..." or "Up to date")
  - Recent activity list (last 10 synced files)
  - Quick actions: "Sync Now", "Pause Sync", "Open Settings"
  - Storage usage bar

### 2. Settings Window

**Connection tab:**
- Server URL input (e.g., `https://sync.example.com` or `http://192.168.1.50:8080`)
- Username / password
- "Test Connection" button
- Connection status indicator

**Sync Tasks tab:**
- List of sync tasks (each pairs a local folder with a remote folder)
- Add/edit/remove sync tasks
- Per task:
  - Local folder path (choose via folder picker)
  - Remote folder (browse server folders)
  - Sync mode: Two-way sync / Upload only (backup)
  - Selective sync: exclude patterns (e.g., `*.tmp`, `node_modules`, `.DS_Store`)
  - Schedule: Continuous (real-time) / Every N minutes / Manual only

**General tab:**
- Launch at login toggle
- Show in menu bar / dock
- Notification preferences (sync complete, errors)
- Log level

### 3. Sync Engine

**Two-way sync algorithm:**
1. Scan local folder for changes (using FSEvents for real-time monitoring)
2. Fetch remote file list from server
3. Compare local vs remote state using the sync database
4. For each file, determine action:
   - Local newer → upload to server
   - Remote newer → download from server
   - Both changed → conflict (keep server version, save local as conflict copy)
   - Local deleted → delete on server
   - Remote deleted → delete locally
   - New local file → upload
   - New remote file → download
5. Execute actions in priority order (folders first, then files)
6. Update sync database with new state

**One-way backup:**
- Same scan + compare, but only uploads (never downloads or deletes remotely)
- Server acts as append-only backup destination

**Initial sync (first run of a new task):**
- If local folder is empty → download all remote files
- If remote folder is empty → upload all local files
- If both have files → treat all files as "new" on both sides; upload local-only files, download remote-only files, for files existing in both locations keep the newer version (by modification time) and save the other as a conflict copy

**File change detection:**
- FSEvents API for real-time local change monitoring
- Polling remote changes via `GET /api/changes?since=<timestamp>` (new endpoint needed on server, returns files changed since timestamp — every 30 seconds by default)
- Fallback: poll `GET /api/files` recursively if change endpoint unavailable
- Content hashing (SHA-256) to detect actual changes vs. just timestamp changes
- Exponential backoff on network failures (1s, 2s, 4s, 8s... max 5 minutes), queued changes retried on reconnect

**Conflict handling:**
- When the same file is modified both locally and remotely before sync completes, the **server's version wins** (server receive timestamp is the authority, per parent spec)
- Local conflicting version saved as `filename_machinename_timestamp.ext`
- Delete-vs-edit conflict: if a file is deleted locally while modified remotely, the remote version is re-downloaded (deletion does not win over edits). If deleted remotely while modified locally, the local version is uploaded as new.
- User notified via macOS Notification Center for conflicts

**Offline behavior:**
- Changes are queued locally while server is unreachable
- On reconnect, queued changes are synced in order
- Notification shown after 5 minutes of unreachable server, then hourly

### 4. File Browser (Optional Window)

- Simple file browser for the remote server (similar to web UI but native)
- Browse folders, download files, view version history
- Accessible via menu bar → "Browse Files"

## Xcode Project Structure

```
SyncVaultApp/
├── SyncVaultApp.xcodeproj
├── SyncVault/
│   ├── App/
│   │   ├── SyncVaultApp.swift           # App entry point, menu bar setup
│   │   └── AppDelegate.swift            # Login item, background setup
│   ├── Views/
│   │   ├── MenuBarView.swift            # Menu bar popover content
│   │   ├── SettingsView.swift           # Settings window
│   │   ├── ConnectionTab.swift          # Server connection settings
│   │   ├── SyncTasksTab.swift           # Sync task management
│   │   ├── GeneralTab.swift             # General preferences
│   │   ├── FileBrowserView.swift        # Remote file browser
│   │   └── Components/
│   │       ├── StorageBar.swift
│   │       ├── SyncStatusBadge.swift
│   │       └── ActivityRow.swift
│   ├── Services/
│   │   ├── APIClient.swift              # REST API client
│   │   ├── AuthService.swift            # Login, token management, Keychain
│   │   ├── SyncEngine.swift             # Core sync logic
│   │   ├── FileWatcher.swift            # FSEvents wrapper
│   │   ├── SyncDatabase.swift           # Local SQLite for sync state
│   │   └── NotificationService.swift    # macOS notification center
│   ├── Models/
│   │   ├── ServerFile.swift             # Remote file model
│   │   ├── SyncTask.swift               # Sync task configuration
│   │   ├── SyncState.swift              # Per-file sync state
│   │   └── AppConfig.swift              # App configuration
│   └── Resources/
│       ├── Assets.xcassets              # App icon, menu bar icons
│       └── Info.plist
├── SyncVaultTests/
│   ├── APIClientTests.swift
│   ├── SyncEngineTests.swift
│   └── SyncDatabaseTests.swift
└── Scripts/
    └── notarize.sh                      # Code signing + notarization script
```

## Build & Distribution

### Code Signing
- Sign with Apple Developer certificate
- Hardened runtime enabled
- App Sandbox enabled (with file access entitlements)

### Notarization
```bash
xcrun notarytool submit SyncVault.dmg \
  --apple-id "developer@email.com" \
  --password "app-specific-password" \
  --team-id "TEAM_ID" \
  --wait
```

### DMG Creation
- Use `create-dmg` or `hdiutil` to create installer DMG
- Background image with drag-to-Applications prompt

### Distribution
- DMG download from GitHub Releases
- Homebrew cask (later)

## Dependencies

- **SQLite.swift** — local sync state database
- **KeychainAccess** — secure credential storage
- No gRPC dependency (uses REST API via URLSession)

## Requirements

- **Minimum macOS version:** macOS 13 Ventura
- **Credentials:** server URL and sync tasks stored in `~/Library/Application Support/SyncVault/config.json`. Passwords and tokens stored exclusively in macOS Keychain (never in config files).
- **Notarization:** credentials via environment variables, never hardcoded in scripts

## New Server Endpoint Needed

The server needs a change feed endpoint for efficient polling:

`GET /api/changes?since=<ISO-timestamp>&folder_id=<optional>`

Returns list of files changed (created, modified, deleted) since the given timestamp. This avoids polling the entire file tree every 30 seconds.

This endpoint must be added to the Go backend before the macOS client can sync efficiently.

## Out of Scope (Phase 3)

- File Provider Extension (on-demand sync) — separate phase
- gRPC streaming (uses REST polling for now)
- Delta sync (entire files transferred, not blocks) — significant bandwidth limitation, planned for later
- Team folder discovery and sync (user must manually configure remote folder paths)
- Share link management from macOS app (use web UI)
- Auto-update mechanism
- Multiple server connections
- Bandwidth throttling
