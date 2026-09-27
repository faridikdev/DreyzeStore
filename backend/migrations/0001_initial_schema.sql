PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS developers (
  id TEXT PRIMARY KEY NOT NULL,
  name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 200),
  website_url TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE IF NOT EXISTS categories (
  id TEXT PRIMARY KEY NOT NULL,
  name TEXT NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 80),
  ordinal INTEGER NOT NULL UNIQUE CHECK (ordinal >= 0)
);

INSERT OR IGNORE INTO categories (id, name, ordinal) VALUES
  ('utilities', 'Utilities', 0),
  ('developer-tools', 'Developer Tools', 1),
  ('games', 'Games', 2),
  ('emulators', 'Emulators', 3),
  ('media', 'Media', 4),
  ('productivity', 'Productivity', 5),
  ('social', 'Social', 6),
  ('customization', 'Customization', 7),
  ('other', 'Other', 8);

CREATE TABLE IF NOT EXISTS repositories (
  id TEXT PRIMARY KEY NOT NULL,
  identifier TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 120),
  manifest_url TEXT NOT NULL UNIQUE,
  trust_level TEXT NOT NULL CHECK (trust_level IN ('official', 'user-confirmed')),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE IF NOT EXISTS apps (
  id TEXT PRIMARY KEY NOT NULL,
  bundle_identifier TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 160),
  developer_id TEXT NOT NULL REFERENCES developers(id),
  category_id TEXT NOT NULL REFERENCES categories(id),
  description TEXT NOT NULL CHECK (length(description) BETWEEN 1 AND 20000),
  icon_object_key TEXT NOT NULL,
  repository_id TEXT NOT NULL REFERENCES repositories(id),
  published INTEGER NOT NULL DEFAULT 0 CHECK (published IN (0, 1)),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  deleted_at TEXT
);

CREATE INDEX IF NOT EXISTS apps_published_updated_idx ON apps (published, updated_at DESC);
CREATE INDEX IF NOT EXISTS apps_category_published_idx ON apps (category_id, published, name);
CREATE INDEX IF NOT EXISTS apps_developer_idx ON apps (developer_id);

CREATE TABLE IF NOT EXISTS versions (
  id TEXT PRIMARY KEY NOT NULL,
  app_id TEXT NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  version TEXT NOT NULL CHECK (length(version) BETWEEN 1 AND 100),
  build TEXT NOT NULL CHECK (length(build) BETWEEN 1 AND 64),
  minimum_ios TEXT NOT NULL,
  ipa_object_key TEXT NOT NULL UNIQUE,
  sha256 TEXT NOT NULL CHECK (length(sha256) = 64 AND sha256 NOT GLOB '*[^a-f0-9]*'),
  size INTEGER NOT NULL CHECK (size BETWEEN 1 AND 4294967296),
  release_notes TEXT NOT NULL DEFAULT '' CHECK (length(release_notes) <= 10000),
  channel TEXT NOT NULL DEFAULT 'stable' CHECK (channel IN ('stable', 'beta')),
  distribution_rights_attested INTEGER NOT NULL DEFAULT 0 CHECK (distribution_rights_attested IN (0, 1)),
  distribution_rights_evidence_url TEXT,
  published_at TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  UNIQUE (app_id, version, build)
);

CREATE INDEX IF NOT EXISTS versions_app_published_idx ON versions (app_id, published_at DESC);

CREATE TABLE IF NOT EXISTS screenshots (
  id TEXT PRIMARY KEY NOT NULL,
  app_id TEXT NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  object_key TEXT NOT NULL,
  width INTEGER NOT NULL CHECK (width BETWEEN 1 AND 16384),
  height INTEGER NOT NULL CHECK (height BETWEEN 1 AND 16384),
  alt_text TEXT NOT NULL CHECK (length(alt_text) BETWEEN 1 AND 240),
  ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
  UNIQUE (app_id, ordinal)
);

CREATE INDEX IF NOT EXISTS screenshots_app_ordinal_idx ON screenshots (app_id, ordinal);

CREATE TABLE IF NOT EXISTS featured (
  id TEXT PRIMARY KEY NOT NULL,
  section_key TEXT NOT NULL CHECK (length(section_key) BETWEEN 1 AND 80),
  app_id TEXT NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
  starts_at TEXT,
  ends_at TEXT,
  UNIQUE (section_key, ordinal)
);

CREATE INDEX IF NOT EXISTS featured_section_order_idx ON featured (section_key, ordinal);

CREATE TABLE IF NOT EXISTS app_daily_downloads (
  app_id TEXT NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  day TEXT NOT NULL,
  request_count INTEGER NOT NULL DEFAULT 0 CHECK (request_count >= 0),
  PRIMARY KEY (app_id, day)
);

CREATE INDEX IF NOT EXISTS app_daily_downloads_day_idx ON app_daily_downloads (day DESC, request_count DESC);

CREATE TABLE IF NOT EXISTS admin_users (
  id TEXT PRIMARY KEY NOT NULL,
  provider TEXT NOT NULL CHECK (length(provider) BETWEEN 1 AND 64),
  subject TEXT NOT NULL CHECK (length(subject) BETWEEN 1 AND 255),
  role TEXT NOT NULL CHECK (role IN ('admin', 'editor')),
  enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  last_auth_at TEXT,
  UNIQUE (provider, subject)
);

CREATE TABLE IF NOT EXISTS admin_sessions (
  token_sha256 TEXT PRIMARY KEY NOT NULL CHECK (length(token_sha256) = 64),
  admin_user_id TEXT NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
  csrf_sha256 TEXT NOT NULL CHECK (length(csrf_sha256) = 64),
  expires_at TEXT NOT NULL,
  revoked_at TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS admin_sessions_expiry_idx ON admin_sessions (expires_at);

CREATE TABLE IF NOT EXISTS audit_logs (
  id TEXT PRIMARY KEY NOT NULL,
  admin_user_id TEXT REFERENCES admin_users(id) ON DELETE SET NULL,
  actor_subject TEXT NOT NULL,
  action TEXT NOT NULL CHECK (length(action) BETWEEN 1 AND 120),
  resource_type TEXT NOT NULL CHECK (length(resource_type) BETWEEN 1 AND 80),
  resource_id TEXT,
  request_id TEXT,
  ip_metadata TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS audit_logs_created_idx ON audit_logs (created_at DESC);
CREATE INDEX IF NOT EXISTS audit_logs_resource_idx ON audit_logs (resource_type, resource_id, created_at DESC);

CREATE TABLE IF NOT EXISTS upload_jobs (
  id TEXT PRIMARY KEY NOT NULL,
  admin_user_id TEXT NOT NULL REFERENCES admin_users(id),
  app_id TEXT REFERENCES apps(id),
  staging_object_key TEXT NOT NULL UNIQUE,
  state TEXT NOT NULL CHECK (state IN ('created', 'uploading', 'queued', 'validating', 'validated', 'rejected', 'published', 'expired')),
  validator_run_id TEXT,
  validation_summary TEXT,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS upload_jobs_state_expiry_idx ON upload_jobs (state, expires_at);

CREATE TABLE IF NOT EXISTS rate_limit_buckets (
  bucket_key_sha256 TEXT PRIMARY KEY NOT NULL CHECK (length(bucket_key_sha256) = 64),
  window_started_at TEXT NOT NULL,
  request_count INTEGER NOT NULL DEFAULT 0 CHECK (request_count >= 0),
  expires_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS rate_limit_buckets_expiry_idx ON rate_limit_buckets (expires_at);
