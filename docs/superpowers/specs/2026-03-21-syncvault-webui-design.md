# SyncVault Web UI — Design Spec

> Phase 2: SvelteKit web interface embedded in the Go server.

## Overview

A modern, minimalist web interface for SyncVault that lets users browse files, manage versions, share links, and (for admins) manage users, teams, and monitor storage. Built with SvelteKit, compiled to static assets, and embedded in the Go binary via `embed`.

## Architecture

### Frontend
- **SvelteKit** in static adapter mode (SSG) — compiles to pure HTML/CSS/JS
- **Tailwind CSS** for styling
- **Lucide icons** for consistent iconography
- Built assets embedded in Go binary via `//go:embed` directive

### Integration with Go Server
- Go serves the SvelteKit build output at `/` (catch-all for SPA routing)
- API calls go to `/api/*` (already exists)
- Single Docker container, no separate frontend server

### Layout
- **Sidebar** (dark, ~240px): logo, navigation (Files, Shared, Trash, Admin section)
- **Content area** (light): header bar with breadcrumbs + user menu, main content below
- **Responsive**: collapses sidebar on mobile

## Pages

### 1. Login Page (`/login`)
- Username + password form
- Stores JWT tokens in localStorage
- Redirects to `/files` on success

### 2. File Browser (`/files`, `/files/:folderId`)
- Grid or list view toggle
- Breadcrumb navigation
- Folder/file icons with name, size, modified date
- Actions: upload (drag & drop + button), create folder, download, rename, move, delete
- Right-click context menu on files
- Bulk selection with checkboxes

### 3. File Details Panel
- Slide-in panel when clicking a file (not folder)
- Shows: name, size, type, owner, created/modified dates
- **Version History** tab: list of versions with date, size, user. Buttons: download version, restore version
- **Sharing** tab: create/manage share links with password, expiration, download limit

### 4. Shared Links (`/shared`)
- List all share links created by current user
- Shows: file name, link URL, downloads used/max, expiration, status
- Actions: copy link, delete link

### 5. Trash (`/trash`)
- List of soft-deleted files
- Actions: restore, permanently delete
- "Empty trash" button

### 6. Admin: Users (`/admin/users`)
- Table of all users: username, email, role, storage used/quota, last active
- Actions: create user, edit, reset password, delete
- Create user modal: username, email, password, role, quota

### 7. Admin: Team Folders (`/admin/teams`)
- List of team folders with name, size, member count
- Create/delete team folders
- Per-folder: manage members and permissions (read/write)

### 8. Admin: Storage (`/admin/storage`)
- Total storage used vs available (bar chart)
- Per-folder breakdown (sorted by size)
- Per-user breakdown
- Version storage usage
- Retention policy settings per folder: form with daily (days), weekly (weeks), monthly (months), yearly (keep forever toggle), max versions slider, rotation algorithm select (FIFO/Intelliversioning). "Clean up now" button per folder

### 9. Admin: Activity Log (`/admin/activity`)
- Filterable table: date, user, action, resource, details
- Filters: user dropdown, action type, date range
- Pagination

## New REST API Endpoints Needed

The following endpoints must be added to the Go backend:

### Version Endpoints
- `GET /api/files/{id}/versions` — list versions of a file
- `POST /api/files/{id}/versions/{versionNum}/restore` — restore a version
- `GET /api/files/{id}/versions/{versionNum}/download` — download specific version

### Share Endpoints
- `POST /api/files/{id}/shares` — create share link
- `GET /api/files/{id}/shares` — list share links for a file
- `DELETE /api/shares/{id}` — delete share link
- `GET /api/shares/mine` — list all share links by current user
- `GET /s/{token}` — public share page: shows file name, size, download button, password prompt if protected (no auth required, server-rendered HTML not SPA)
- `GET /s/{token}/download` — public file download (no auth, checks password/expiry/limit)

### Team Endpoints
- `GET /api/teams` — list team folders (admin: all, user: own)
- `POST /api/teams` — create team folder (admin only)
- `DELETE /api/teams/{id}` — delete team folder (admin only)
- `GET /api/teams/{id}/members` — list members with permissions
- `PUT /api/teams/{id}/members/{userId}` — set permission
- `DELETE /api/teams/{id}/members/{userId}` — remove member

### Admin Endpoints
- `GET /api/admin/users` — list all users with storage stats
- `PUT /api/admin/users/{id}` — update user (role, quota, email)
- `DELETE /api/admin/users/{id}` — delete user
- `POST /api/admin/users/{id}/reset-password` — reset password
- `GET /api/admin/storage` — storage overview (total, per-user, per-folder)
- `GET /api/admin/activity` — activity log with filters
- `GET /api/admin/devices` — connected devices (shown in Users page as expandable row)

### File Operations
- `PUT /api/files/{id}` — rename/move file (body: `{name, parent_id}`)
- `DELETE /api/files/{id}` — soft delete (trash)
- `POST /api/files/{id}/restore` — restore from trash
- `DELETE /api/files/{id}/permanent` — permanent delete
- `GET /api/trash` — list trashed files

## SvelteKit Project Structure

```
web/
├── src/
│   ├── lib/
│   │   ├── api.ts              # API client (fetch wrapper with auth)
│   │   ├── auth.ts             # Token management (localStorage)
│   │   ├── stores.ts           # Svelte stores (user, files)
│   │   └── components/
│   │       ├── Sidebar.svelte
│   │       ├── FileGrid.svelte
│   │       ├── FileList.svelte
│   │       ├── FileDetails.svelte
│   │       ├── VersionHistory.svelte
│   │       ├── ShareManager.svelte
│   │       ├── BreadcrumbNav.svelte
│   │       ├── UserMenu.svelte
│   │       ├── Modal.svelte
│   │       ├── DataTable.svelte
│   │       └── StorageBar.svelte
│   ├── routes/
│   │   ├── +layout.svelte      # App shell (sidebar + content)
│   │   ├── +page.svelte        # Redirect to /files
│   │   ├── login/+page.svelte
│   │   ├── files/
│   │   │   ├── +page.svelte          # Root file browser
│   │   │   └── [folderId]/+page.svelte
│   │   ├── shared/+page.svelte
│   │   ├── trash/+page.svelte
│   │   └── admin/
│   │       ├── users/+page.svelte
│   │       ├── teams/+page.svelte
│   │       ├── storage/+page.svelte
│   │       └── activity/+page.svelte
│   └── app.css                 # Tailwind base + custom styles
├── static/
│   └── favicon.svg
├── svelte.config.js
├── tailwind.config.js
├── vite.config.ts
└── package.json
```

## Go Embedding

```go
// internal/api/rest/spa.go
//go:embed all:dist
var spaFiles embed.FS

// Serve SPA: try static file first, fallback to index.html for SPA routing
```

The SvelteKit build output goes to `internal/api/rest/dist/`. The Go binary embeds these files and serves them.

**Routing priority** (in chi router order):
1. `/api/*` — REST API endpoints (highest priority)
2. `/s/{token}` and `/s/{token}/download` — public share routes
3. Static files from embedded SPA (JS, CSS, images)
4. Everything else → `index.html` (SPA catch-all for client-side routing)

## Build Pipeline

1. `cd web && npm run build` — builds SvelteKit to `../internal/api/rest/dist/`
2. `go build ./cmd/server/` — embeds the built frontend
3. Docker: Dockerfile adds Node.js build stage before Go build

## Design Style

- **Sidebar**: dark (#1e1e2e), white text, icons + labels
- **Content**: light background (#f8f9fa), cards with subtle shadows
- **Accent**: blue (#3b82f6) for primary actions
- **Typography**: system font stack (Inter if available)
- **Icons**: Lucide (consistent, clean line icons)
- **Tables**: clean with hover states, sortable columns
- **Modals**: centered overlay with backdrop blur

## Notes

- `POST /api/files` with `is_dir: true` already exists for creating folders
- `POST /api/files/upload` already exists for file uploads
- Permanent delete and empty trash available to all users for their own files (admin can delete anyone's)

## Out of Scope

- Real-time updates (WebSocket) — files refresh on navigation
- File preview (images, PDFs) — just download for now
- Drag & drop file organization (move via context menu)
- Dark mode toggle (dark sidebar only)
- Folder sharing via link (only file sharing for now)
- Conflict resolution UI (deferred to macOS app phase)
- Connected devices as separate admin page (shown inline in users table)
