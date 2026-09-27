CREATE TABLE admin_password_credentials_argon2id (
  admin_user_id TEXT PRIMARY KEY NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
  password_hash TEXT NOT NULL CHECK (length(password_hash) = 64 AND password_hash NOT GLOB '*[^a-f0-9]*'),
  password_salt TEXT NOT NULL CHECK (length(password_salt) = 64 AND password_salt NOT GLOB '*[^a-f0-9]*'),
  algorithm TEXT NOT NULL CHECK (algorithm IN ('argon2id-v1', 'PBKDF2-HMAC-SHA256')),
  iterations INTEGER NOT NULL,
  memory_kib INTEGER NOT NULL CHECK (memory_kib = 19456),
  parallelism INTEGER NOT NULL CHECK (parallelism = 1),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  CHECK (
    (algorithm = 'argon2id-v1' AND iterations = 2)
    OR (algorithm = 'PBKDF2-HMAC-SHA256' AND iterations BETWEEN 600000 AND 1200000)
  )
);

INSERT INTO admin_password_credentials_argon2id (
  admin_user_id, password_hash, password_salt, algorithm, iterations, memory_kib, parallelism, updated_at
)
SELECT admin_user_id, password_hash, password_salt, algorithm, iterations, 19456, 1, updated_at
FROM admin_password_credentials;

DROP TABLE admin_password_credentials;
ALTER TABLE admin_password_credentials_argon2id RENAME TO admin_password_credentials;
