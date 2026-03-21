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

**File change detection:**
- FSEvents API for real-time local change monitoring
- Polling remote changes via `GET /api/files` (every 30 seconds by default)
- Content hashing (SHA-256) to detect actual changes vs. just timestamp changes

**Conflict handling:**
- Server version wins (consistent with spec)
- Local conflicting file saved as `filename_machinename_timestamp.ext`
- User notified via notification center

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

## Out of Scope (Phase 3)

- File Provider Extension (on-demand sync) — separate phase
- gRPC streaming (uses REST polling for now)
- Auto-update mechanism
- Multiple server connections
- Bandwidth throttling
