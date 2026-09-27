ALTER TABLE apps
  ADD COLUMN short_description TEXT NOT NULL DEFAULT '' CHECK (length(short_description) <= 160);

CREATE TABLE admin_password_credentials (
  admin_user_id TEXT PRIMARY KEY NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
  password_hash TEXT NOT NULL CHECK (length(password_hash) = 64 AND password_hash NOT GLOB '*[^a-f0-9]*'),
  password_salt TEXT NOT NULL CHECK (length(password_salt) = 64 AND password_salt NOT GLOB '*[^a-f0-9]*'),
  algorithm TEXT NOT NULL DEFAULT 'PBKDF2-HMAC-SHA256' CHECK (algorithm = 'PBKDF2-HMAC-SHA256'),
  iterations INTEGER NOT NULL CHECK (iterations BETWEEN 600000 AND 1200000),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

DROP INDEX IF EXISTS upload_jobs_state_expiry_idx;
ALTER TABLE upload_jobs RENAME TO upload_jobs_legacy;

CREATE TABLE upload_jobs (
  id TEXT PRIMARY KEY NOT NULL,
  admin_user_id TEXT NOT NULL REFERENCES admin_users(id),
  app_id TEXT REFERENCES apps(id),
  staging_object_key TEXT NOT NULL UNIQUE,
  state TEXT NOT NULL CHECK (state IN (
    'created', 'uploading', 'uploaded', 'queued', 'validating',
    'validation_failed', 'ready_for_review', 'publishing', 'published', 'rejected', 'expired'
  )),
  expected_size INTEGER NOT NULL CHECK (expected_size BETWEEN 1 AND 1073741824),
  expected_content_type TEXT NOT NULL DEFAULT 'application/octet-stream'
    CHECK (expected_content_type = 'application/octet-stream'),
  object_etag TEXT,
  validator_nonce_sha256 TEXT NOT NULL CHECK (length(validator_nonce_sha256) = 64 AND validator_nonce_sha256 NOT GLOB '*[^a-f0-9]*'),
  validator_run_id TEXT,
  validator_run_attempt INTEGER CHECK (validator_run_attempt IS NULL OR validator_run_attempt BETWEEN 1 AND 1000000),
  detected_bundle_identifier TEXT,
  detected_version TEXT,
  detected_build TEXT,
  detected_minimum_ios TEXT,
  detected_display_name TEXT,
  actual_size INTEGER CHECK (actual_size BETWEEN 1 AND 1073741824),
  sha256 TEXT CHECK (sha256 IS NULL OR (length(sha256) = 64 AND sha256 NOT GLOB '*[^a-f0-9]*')),
  validation_error_code TEXT,
  release_notes TEXT NOT NULL DEFAULT '' CHECK (length(release_notes) <= 10000),
  channel TEXT NOT NULL DEFAULT 'stable' CHECK (channel IN ('stable', 'beta')),
  published_object_key TEXT UNIQUE,
  expires_at TEXT NOT NULL,
  completed_at TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  CHECK (state != 'ready_for_review' OR (
    detected_bundle_identifier IS NOT NULL AND detected_version IS NOT NULL AND detected_build IS NOT NULL
    AND detected_minimum_ios IS NOT NULL AND actual_size IS NOT NULL AND sha256 IS NOT NULL
  )),
  CHECK (state != 'published' OR published_object_key IS NOT NULL)
);

INSERT INTO upload_jobs (
  id, admin_user_id, app_id, staging_object_key, state,
  expected_size, validator_nonce_sha256, validator_run_id,
  expires_at, created_at, updated_at
)
SELECT
  id, admin_user_id, app_id, staging_object_key,
  CASE state WHEN 'validated' THEN 'validation_failed' WHEN 'published' THEN 'expired' ELSE state END,
  1, lower(hex(randomblob(32))), validator_run_id, expires_at, created_at, updated_at
FROM upload_jobs_legacy;

DROP TABLE upload_jobs_legacy;
CREATE INDEX upload_jobs_state_expiry_idx ON upload_jobs (state, expires_at);
CREATE INDEX upload_jobs_admin_created_idx ON upload_jobs (admin_user_id, created_at DESC);
CREATE INDEX upload_jobs_app_state_idx ON upload_jobs (app_id, state, created_at DESC);

CREATE TABLE admin_asset_uploads (
  id TEXT PRIMARY KEY NOT NULL,
  admin_user_id TEXT NOT NULL REFERENCES admin_users(id),
  app_id TEXT NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('icon', 'screenshot')),
  staging_object_key TEXT NOT NULL UNIQUE,
  expected_size INTEGER NOT NULL CHECK (expected_size BETWEEN 1 AND 10485760),
  content_type TEXT NOT NULL CHECK (content_type IN ('image/png', 'image/jpeg')),
  alt_text TEXT NOT NULL DEFAULT '' CHECK (length(alt_text) <= 240 AND (kind = 'icon' OR length(alt_text) >= 1)),
  state TEXT NOT NULL CHECK (state IN ('uploading', 'uploaded', 'published', 'expired')),
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX admin_asset_uploads_app_idx ON admin_asset_uploads (app_id, created_at DESC);
CREATE INDEX admin_asset_uploads_expiry_idx ON admin_asset_uploads (state, expires_at);

CREATE TABLE distribution_rights_attestations (
  id TEXT PRIMARY KEY NOT NULL,
  upload_id TEXT NOT NULL UNIQUE REFERENCES upload_jobs(id),
  release_id TEXT NOT NULL REFERENCES versions(id),
  admin_user_id TEXT NOT NULL REFERENCES admin_users(id),
  attestation_version TEXT NOT NULL CHECK (attestation_version = 'v1'),
  confirmed INTEGER NOT NULL CHECK (confirmed = 1),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX rights_attestations_admin_idx ON distribution_rights_attestations (admin_user_id, created_at DESC);

CREATE TRIGGER apps_bundle_identifier_locked
BEFORE UPDATE OF bundle_identifier ON apps
WHEN EXISTS (SELECT 1 FROM versions WHERE app_id = OLD.id)
BEGIN
  SELECT RAISE(ABORT, 'bundle identifier is immutable after first release');
END;

CREATE TRIGGER admin_upload_requires_matching_app_insert
BEFORE INSERT ON upload_jobs
WHEN NEW.app_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM apps WHERE id = NEW.app_id AND deleted_at IS NULL)
BEGIN
  SELECT RAISE(ABORT, 'upload requires an existing application');
END;

CREATE TRIGGER admin_upload_requires_matching_app_update
BEFORE UPDATE OF app_id ON upload_jobs
WHEN NEW.app_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM apps WHERE id = NEW.app_id AND deleted_at IS NULL)
BEGIN
  SELECT RAISE(ABORT, 'upload requires an existing application');
END;
