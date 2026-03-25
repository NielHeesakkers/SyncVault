# SyncVault

Open-source file sync and backup platform. A self-hosted alternative to Synology Drive.

## Features

- **File Sync** — Two-way sync between your devices and the server
- **Backup** — One-way backup (continuous, scheduled, or manual)
- **On-Demand Sync** — Files appear in Finder but download only when opened (coming soon)
- **File Versioning** — Up to 32 versions per file with delta patches
- **Team Folders** — Shared folders with per-user read/write permissions
- **Share Links** — Password-protected download links with expiration and download limits
- **Web Interface** — Browse files, manage versions, admin panel
- **macOS App** — Native menu bar app with sync engine
- **Storage Insights** — Per-folder and per-user storage breakdown
- **Activity Log** — Track who did what, filterable by user, action, and date
- **Retention Policies** — Automatic cleanup with daily/weekly/monthly/yearly tiers
- **Docker Deployment** — Single container, easy to run anywhere

## Architecture

| Component | Technology |
|-----------|-----------|
| Server | Go (modular monolith) |
| Web UI | SvelteKit + Tailwind CSS |
| macOS App | Swift + SwiftUI |
| Database | SQLite |
| File Storage | Content-addressable with chunking and deduplication |
| Auth | JWT + bcrypt |
| Versioning | Binary delta patches |

## Quick Start

### Docker Compose

```yaml
version: "3.8"

services:
  syncvault:
    image: ghcr.io/nielheesakkers/syncvault:latest
    container_name: syncvault
    ports:
      - "8080:8080"
    volumes:
      - syncvault-data:/data
    environment:
      - SYNCVAULT_JWT_SECRET=change-this-to-a-long-random-string
    restart: unless-stopped

volumes:
  syncvault-data:
```

### Run with Docker

```bash
docker run -d \
  -p 8080:8080 \
  -v syncvault-data:/data \
  -e SYNCVAULT_JWT_SECRET=your-secret-here \
  ghcr.io/nielheesakkers/syncvault:latest
```

### Build from Source

```bash
git clone https://github.com/NielHeesakkers/SyncVault.git
cd SyncVault

# Build and run
make run

# Or with Docker
docker compose up --build
```

## Default Login

After first start, a default admin account is created:

- **Username:** `admin`
- **Password:** `admin`

**Change this immediately** after first login.

## Configuration

All configuration is via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `SYNCVAULT_DATA_DIR` | `/data` | Data directory for files and database |
| `SYNCVAULT_HTTP_PORT` | `8080` | HTTP port for REST API and Web UI |
| `SYNCVAULT_GRPC_PORT` | `6690` | gRPC port for sync clients |
| `SYNCVAULT_JWT_SECRET` | (random) | Secret key for JWT tokens |
| `SYNCVAULT_TLS_CERT` | | Path to TLS certificate (optional) |
| `SYNCVAULT_TLS_KEY` | | Path to TLS private key (optional) |
| `SYNCVAULT_CHUNK_SIZE` | `4194304` | File chunk size in bytes (4MB) |

## Storage

Data is stored in the configured data directory:

```
/data/
├── vault.db        # SQLite database (users, files, versions, permissions)
├── chunks/         # File content (content-addressable, deduplicated)
└── config.json     # Server configuration (optional)
```

### Separate Storage Location

To store file chunks on a different disk (e.g., external drive):

```yaml
volumes:
  - syncvault-data:/data
  - /path/to/large/disk:/data/chunks
```

## Portainer Deployment

1. Go to **Stacks** > **Add stack**
2. Paste the Docker Compose YAML from above
3. Set `SYNCVAULT_JWT_SECRET` to a secure random string
4. Click **Deploy the stack**

See `docker-compose.portainer.yml` for a ready-to-use Portainer compose file with all options.

## Reverse Proxy (Nginx Proxy Manager)

If you use Nginx Proxy Manager as a reverse proxy, add this to the **Advanced** > **Custom Nginx Configuration** of your proxy host to support large file uploads:

```nginx
client_max_body_size 0;
proxy_read_timeout 86400;
proxy_send_timeout 86400;
proxy_connect_timeout 86400;
proxy_request_buffering off;
```

This removes the upload size limit, sets 24-hour timeouts for large file transfers, and disables request buffering for direct streaming.

## API

The REST API is available at `/api/*`. Key endpoints:

### Authentication
- `POST /api/auth/login` — Login with username/password
- `POST /api/auth/refresh` — Refresh access token

### Files
- `GET /api/files?parent_id=` — List files in a folder
- `POST /api/files` — Create folder
- `POST /api/files/upload` — Upload file (multipart)
- `GET /api/files/{id}/download` — Download file
- `PUT /api/files/{id}` — Rename/move file
- `DELETE /api/files/{id}` — Delete file (trash)
- `GET /api/changes?since=` — Change feed for sync clients

### Versions
- `GET /api/files/{id}/versions` — List file versions
- `GET /api/files/{id}/versions/{num}/download` — Download specific version
- `POST /api/files/{id}/versions/{num}/restore` — Restore version

### Sharing
- `POST /api/files/{id}/shares` — Create share link
- `GET /s/{token}` — Public share page
- `POST /s/{token}/download` — Public file download

### Teams
- `GET /api/teams` — List team folders
- `POST /api/teams` — Create team folder (admin)
- `PUT /api/teams/{id}/members/{userId}` — Set member permission

### Admin
- `GET /api/admin/users` — List users with storage stats
- `GET /api/admin/storage` — Storage overview
- `GET /api/admin/activity` — Activity log

## macOS App

The native macOS app lives in `macos/`. It provides:

- Menu bar icon with sync status
- Two-way file sync and one-way backup
- Settings UI for server connection and sync tasks
- Local file change monitoring via FSEvents
- Secure credential storage in macOS Keychain

Build with:

```bash
cd macos
swift build
```

## Development

```bash
# Run server locally
make run

# Run tests
make test

# Build Docker image
make docker

# Frontend development (with hot reload)
cd web && npm run dev
```

## License

MIT
