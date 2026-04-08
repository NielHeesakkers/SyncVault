CREATE TABLE IF NOT EXISTS users (
    id                   TEXT PRIMARY KEY,
    username             TEXT NOT NULL UNIQUE,
    email                TEXT NOT NULL UNIQUE,
    password             TEXT NOT NULL,
    role                 TEXT NOT NULL CHECK(role IN ('admin', 'user')),
    quota_bytes          INTEGER NOT NULL DEFAULT 0,
    token_invalidated_at TEXT,
    created_at           TEXT NOT NULL,
    updated_at           TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS files (
    id               TEXT PRIMARY KEY,
    parent_id        TEXT REFERENCES files(id),
    owner_id         TEXT NOT NULL REFERENCES users(id),
    name             TEXT NOT NULL,
    is_dir           INTEGER NOT NULL DEFAULT 0,
    size             INTEGER NOT NULL DEFAULT 0,
    content_hash     TEXT,
    mime_type        TEXT,
    created_at       TEXT NOT NULL,
    updated_at       TEXT NOT NULL,
    deleted_at       TEXT,
    removed_locally  INTEGER NOT NULL DEFAULT 0,
    UNIQUE(parent_id, name, owner_id)
);

CREATE TABLE IF NOT EXISTS versions (
    id           TEXT PRIMARY KEY,
    file_id      TEXT NOT NULL REFERENCES files(id),
    version_num  INTEGER NOT NULL,
    content_hash TEXT NOT NULL,
    patch_hash   TEXT,
    size         INTEGER NOT NULL DEFAULT 0,
    created_by   TEXT NOT NULL REFERENCES users(id),
    created_at   TEXT NOT NULL,
    UNIQUE(file_id, version_num)
);

CREATE TABLE IF NOT EXISTS team_folders (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    quota_bytes INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS team_permissions (
    id             TEXT PRIMARY KEY,
    team_folder_id TEXT NOT NULL REFERENCES team_folders(id),
    user_id        TEXT NOT NULL REFERENCES users(id),
    permission     TEXT NOT NULL CHECK(permission IN ('read', 'write', 'readwrite')),
    UNIQUE(team_folder_id, user_id)
);

CREATE TABLE IF NOT EXISTS devices (
    id         TEXT PRIMARY KEY,
    user_id    TEXT NOT NULL REFERENCES users(id),
    name       TEXT NOT NULL,
    platform   TEXT,
    last_seen  TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS activity_log (
    id          TEXT PRIMARY KEY,
    user_id     TEXT REFERENCES users(id),
    action      TEXT NOT NULL,
    resource    TEXT,
    resource_id TEXT,
    details     TEXT,
    ip_address  TEXT,
    created_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS share_links (
    id             TEXT PRIMARY KEY,
    file_id        TEXT NOT NULL REFERENCES files(id),
    token          TEXT NOT NULL UNIQUE,
    password_hash  TEXT,
    expires_at     TEXT,
    max_downloads  INTEGER,
    download_count INTEGER NOT NULL DEFAULT 0,
    created_by     TEXT NOT NULL REFERENCES users(id),
    created_at     TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS retention_policies (
    id             TEXT PRIMARY KEY,
    team_folder_id TEXT REFERENCES team_folders(id),
    sync_task_id   TEXT REFERENCES sync_tasks(id) ON DELETE CASCADE,
    hourly_hours   INTEGER DEFAULT 0,
    daily_days     INTEGER DEFAULT 0,
    weekly_weeks   INTEGER DEFAULT 0,
    monthly_months INTEGER DEFAULT 0,
    yearly_years   INTEGER DEFAULT 0,
    max_versions   INTEGER DEFAULT 0,
    UNIQUE(sync_task_id)
);

CREATE TABLE IF NOT EXISTS sync_state (
    device_id   TEXT NOT NULL REFERENCES devices(id),
    file_id     TEXT NOT NULL REFERENCES files(id),
    version_num INTEGER NOT NULL,
    synced_at   TEXT NOT NULL,
    PRIMARY KEY (device_id, file_id)
);

CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sync_tasks (
    id          TEXT PRIMARY KEY,
    user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    folder_id   TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    type        TEXT NOT NULL CHECK(type IN ('sync', 'backup', 'ondemand')),
    local_path  TEXT,
    status      TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active', 'paused')),
    created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_id, name)
);
CREATE INDEX IF NOT EXISTS idx_sync_tasks_user ON sync_tasks(user_id);

CREATE TABLE IF NOT EXISTS notifications (
    id          TEXT PRIMARY KEY,
    user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type        TEXT NOT NULL,
    title       TEXT NOT NULL,
    message     TEXT,
    data        TEXT,
    read        INTEGER NOT NULL DEFAULT 0,
    acted       INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_notifications_user ON notifications(user_id);

CREATE TABLE IF NOT EXISTS password_resets (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    token TEXT NOT NULL UNIQUE,
    expires_at TEXT NOT NULL,
    used INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS connection_tokens (
    user_id        TEXT PRIMARY KEY REFERENCES users(id),
    encrypted_data BLOB NOT NULL,
    used           INTEGER NOT NULL DEFAULT 0,
    created_at     TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS sync_states (
    id           TEXT PRIMARY KEY,
    user_id      TEXT NOT NULL REFERENCES users(id),
    device_id    TEXT NOT NULL,
    task_name    TEXT NOT NULL,
    file_path    TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    synced_at    TEXT NOT NULL,
    UNIQUE(user_id, device_id, task_name, file_path)
);

CREATE TABLE IF NOT EXISTS upload_sessions (
    id             TEXT PRIMARY KEY,
    user_id        TEXT NOT NULL REFERENCES users(id),
    parent_id      TEXT REFERENCES files(id),
    filename       TEXT NOT NULL,
    total_size     INTEGER NOT NULL,
    chunk_size     INTEGER NOT NULL,
    total_chunks   INTEGER NOT NULL,
    received_chunks TEXT NOT NULL DEFAULT '[]',
    created_at     TEXT NOT NULL,
    expires_at     TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS file_blocks (
    file_id      TEXT NOT NULL REFERENCES files(id),
    version_num  INTEGER NOT NULL,
    block_index  INTEGER NOT NULL,
    weak_hash    INTEGER NOT NULL,
    strong_hash  TEXT NOT NULL,
    PRIMARY KEY (file_id, version_num, block_index)
);

CREATE TABLE IF NOT EXISTS file_locks (
    file_id    TEXT PRIMARY KEY,
    user_id    TEXT NOT NULL,
    username   TEXT NOT NULL,
    device     TEXT NOT NULL DEFAULT '',
    locked_at  TEXT NOT NULL,
    expires_at TEXT NOT NULL
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_files_parent_id    ON files(parent_id);
CREATE INDEX IF NOT EXISTS idx_files_owner_id     ON files(owner_id);
CREATE INDEX IF NOT EXISTS idx_files_deleted_at   ON files(deleted_at);
CREATE INDEX IF NOT EXISTS idx_versions_file_id   ON versions(file_id);
CREATE INDEX IF NOT EXISTS idx_versions_file_time ON versions(file_id, created_at, version_num);
CREATE INDEX IF NOT EXISTS idx_devices_user_id    ON devices(user_id);
CREATE INDEX IF NOT EXISTS idx_activity_user_id   ON activity_log(user_id);
CREATE INDEX IF NOT EXISTS idx_activity_created   ON activity_log(created_at);
CREATE INDEX IF NOT EXISTS idx_share_token        ON share_links(token);
CREATE INDEX IF NOT EXISTS idx_upload_sessions_user ON upload_sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_file_blocks_file   ON file_blocks(file_id);
