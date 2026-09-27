ALTER TABLE repositories
  ADD COLUMN description TEXT NOT NULL DEFAULT '' CHECK (length(description) <= 4000);

ALTER TABLE repositories
  ADD COLUMN icon_object_key TEXT NOT NULL DEFAULT 'icons/repository-default.png';

CREATE UNIQUE INDEX IF NOT EXISTS repositories_single_official_idx
  ON repositories (trust_level)
  WHERE trust_level = 'official';

CREATE INDEX IF NOT EXISTS apps_catalog_name_idx
  ON apps (name COLLATE NOCASE, id)
  WHERE published = 1 AND deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS apps_catalog_category_name_idx
  ON apps (category_id, name COLLATE NOCASE, id)
  WHERE published = 1 AND deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS apps_catalog_repository_name_idx
  ON apps (repository_id, name COLLATE NOCASE, id)
  WHERE published = 1 AND deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS apps_catalog_updated_idx
  ON apps (updated_at DESC, id)
  WHERE published = 1 AND deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS apps_catalog_newest_idx
  ON apps (created_at DESC, id)
  WHERE published = 1 AND deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS versions_published_app_date_idx
  ON versions (app_id, published_at DESC, id DESC)
  WHERE published_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS featured_active_order_idx
  ON featured (section_key, starts_at, ends_at, ordinal, app_id);

CREATE UNIQUE INDEX IF NOT EXISTS featured_section_app_unique_idx
  ON featured (section_key, app_id);

CREATE TRIGGER IF NOT EXISTS apps_require_published_release_insert
BEFORE INSERT ON apps
WHEN NEW.published = 1 AND NEW.deleted_at IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM versions
    WHERE app_id = NEW.id AND published_at IS NOT NULL
  )
BEGIN
  SELECT RAISE(ABORT, 'a published app requires a published version');
END;

CREATE TRIGGER IF NOT EXISTS apps_require_published_release_update
BEFORE UPDATE OF published, deleted_at ON apps
WHEN NEW.published = 1 AND NEW.deleted_at IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM versions
    WHERE app_id = NEW.id AND published_at IS NOT NULL
  )
BEGIN
  SELECT RAISE(ABORT, 'a published app requires a published version');
END;

CREATE TRIGGER IF NOT EXISTS apps_published_per_repository_insert
BEFORE INSERT ON apps
WHEN NEW.published = 1 AND NEW.deleted_at IS NULL
  AND (SELECT COUNT(*) FROM apps
       WHERE repository_id = NEW.repository_id
         AND published = 1 AND deleted_at IS NULL) >= 1000
BEGIN
  SELECT RAISE(ABORT, 'repository app limit exceeded');
END;

CREATE TRIGGER IF NOT EXISTS apps_published_per_repository_update
BEFORE UPDATE OF published, deleted_at, repository_id ON apps
WHEN NEW.published = 1 AND NEW.deleted_at IS NULL
  AND (SELECT COUNT(*) FROM apps
       WHERE repository_id = NEW.repository_id
         AND published = 1 AND deleted_at IS NULL AND id <> OLD.id) >= 1000
BEGIN
  SELECT RAISE(ABORT, 'repository app limit exceeded');
END;

CREATE TRIGGER IF NOT EXISTS versions_published_per_app_insert
BEFORE INSERT ON versions
WHEN NEW.published_at IS NOT NULL
  AND (SELECT COUNT(*) FROM versions
       WHERE app_id = NEW.app_id AND published_at IS NOT NULL) >= 50
BEGIN
  SELECT RAISE(ABORT, 'published version limit exceeded');
END;

CREATE TRIGGER IF NOT EXISTS versions_published_per_app_update
BEFORE UPDATE OF app_id, published_at ON versions
WHEN NEW.published_at IS NOT NULL
  AND (SELECT COUNT(*) FROM versions
       WHERE app_id = NEW.app_id AND published_at IS NOT NULL AND id <> OLD.id) >= 50
BEGIN
  SELECT RAISE(ABORT, 'published version limit exceeded');
END;

CREATE TRIGGER IF NOT EXISTS screenshots_per_app_insert
BEFORE INSERT ON screenshots
WHEN (SELECT COUNT(*) FROM screenshots WHERE app_id = NEW.app_id) >= 20
BEGIN
  SELECT RAISE(ABORT, 'screenshot limit exceeded');
END;

CREATE TRIGGER IF NOT EXISTS screenshots_per_app_update
BEFORE UPDATE OF app_id ON screenshots
WHEN (SELECT COUNT(*) FROM screenshots WHERE app_id = NEW.app_id AND id <> OLD.id) >= 20
BEGIN
  SELECT RAISE(ABORT, 'screenshot limit exceeded');
END;

CREATE TRIGGER IF NOT EXISTS featured_section_insert
BEFORE INSERT ON featured
WHEN NEW.section_key NOT IN ('hero', 'editors-picks', 'new-releases', 'recently-updated', 'popular')
  OR (SELECT COUNT(*) FROM featured WHERE section_key = NEW.section_key) >= 20
  OR (NEW.starts_at IS NOT NULL AND strftime('%Y-%m-%dT%H:%M:%fZ', NEW.starts_at) IS NULL)
  OR (NEW.ends_at IS NOT NULL AND strftime('%Y-%m-%dT%H:%M:%fZ', NEW.ends_at) IS NULL)
  OR (NEW.starts_at IS NOT NULL AND NEW.ends_at IS NOT NULL AND NEW.ends_at < NEW.starts_at)
BEGIN
  SELECT RAISE(ABORT, 'invalid featured content');
END;

CREATE TRIGGER IF NOT EXISTS featured_section_update
BEFORE UPDATE OF section_key, starts_at, ends_at ON featured
WHEN NEW.section_key NOT IN ('hero', 'editors-picks', 'new-releases', 'recently-updated', 'popular')
  OR (SELECT COUNT(*) FROM featured
      WHERE section_key = NEW.section_key AND id <> OLD.id) >= 20
  OR (NEW.starts_at IS NOT NULL AND strftime('%Y-%m-%dT%H:%M:%fZ', NEW.starts_at) IS NULL)
  OR (NEW.ends_at IS NOT NULL AND strftime('%Y-%m-%dT%H:%M:%fZ', NEW.ends_at) IS NULL)
  OR (NEW.starts_at IS NOT NULL AND NEW.ends_at IS NOT NULL AND NEW.ends_at < NEW.starts_at)
BEGIN
  SELECT RAISE(ABORT, 'invalid featured content');
END;

CREATE VIRTUAL TABLE IF NOT EXISTS app_search USING fts5(
  app_id UNINDEXED,
  name,
  developer,
  bundle_identifier,
  description,
  category,
  tokenize = 'unicode61 remove_diacritics 2'
);

CREATE TRIGGER IF NOT EXISTS app_search_insert
AFTER INSERT ON apps
WHEN NEW.published = 1 AND NEW.deleted_at IS NULL
BEGIN
  INSERT INTO app_search (app_id, name, developer, bundle_identifier, description, category)
  SELECT NEW.id, NEW.name, d.name, NEW.bundle_identifier, NEW.description, c.name
  FROM developers AS d JOIN categories AS c ON c.id = NEW.category_id
  WHERE d.id = NEW.developer_id;
END;

CREATE TRIGGER IF NOT EXISTS app_search_update
AFTER UPDATE OF name, bundle_identifier, developer_id, category_id, description, published, deleted_at ON apps
BEGIN
  DELETE FROM app_search WHERE app_id = OLD.id;
  INSERT INTO app_search (app_id, name, developer, bundle_identifier, description, category)
  SELECT NEW.id, NEW.name, d.name, NEW.bundle_identifier, NEW.description, c.name
  FROM developers AS d JOIN categories AS c ON c.id = NEW.category_id
  WHERE d.id = NEW.developer_id AND NEW.published = 1 AND NEW.deleted_at IS NULL;
END;

CREATE TRIGGER IF NOT EXISTS app_search_delete
AFTER DELETE ON apps
BEGIN
  DELETE FROM app_search WHERE app_id = OLD.id;
END;

CREATE TRIGGER IF NOT EXISTS app_search_developer_update
AFTER UPDATE OF name ON developers
BEGIN
  DELETE FROM app_search
  WHERE app_id IN (SELECT id FROM apps WHERE developer_id = NEW.id);
  INSERT INTO app_search (app_id, name, developer, bundle_identifier, description, category)
  SELECT a.id, a.name, NEW.name, a.bundle_identifier, a.description, c.name
  FROM apps AS a JOIN categories AS c ON c.id = a.category_id
  WHERE a.developer_id = NEW.id AND a.published = 1 AND a.deleted_at IS NULL;
END;

CREATE TRIGGER IF NOT EXISTS app_search_category_update
AFTER UPDATE OF name ON categories
BEGIN
  DELETE FROM app_search
  WHERE app_id IN (SELECT id FROM apps WHERE category_id = NEW.id);
  INSERT INTO app_search (app_id, name, developer, bundle_identifier, description, category)
  SELECT a.id, a.name, d.name, a.bundle_identifier, a.description, NEW.name
  FROM apps AS a JOIN developers AS d ON d.id = a.developer_id
  WHERE a.category_id = NEW.id AND a.published = 1 AND a.deleted_at IS NULL;
END;

INSERT INTO app_search (app_id, name, developer, bundle_identifier, description, category)
SELECT a.id, a.name, d.name, a.bundle_identifier, a.description, c.name
FROM apps AS a
JOIN developers AS d ON d.id = a.developer_id
JOIN categories AS c ON c.id = a.category_id
WHERE a.published = 1
  AND a.deleted_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM app_search WHERE app_id = a.id);
