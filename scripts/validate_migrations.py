from pathlib import Path
import sqlite3


ROOT = Path(__file__).resolve().parents[1]
MIGRATIONS = ROOT / "backend" / "migrations"
EXPECTED_TABLES = {
    "developers",
    "categories",
    "repositories",
    "apps",
    "versions",
    "screenshots",
    "featured",
    "app_daily_downloads",
    "admin_users",
    "admin_sessions",
    "audit_logs",
    "upload_jobs",
    "rate_limit_buckets",
    "app_search",
}
EXPECTED_INDEXES = {
    "apps_published_updated_idx",
    "apps_category_published_idx",
    "apps_developer_idx",
    "versions_app_published_idx",
    "screenshots_app_ordinal_idx",
    "featured_section_order_idx",
    "app_daily_downloads_day_idx",
    "admin_sessions_expiry_idx",
    "audit_logs_created_idx",
    "audit_logs_resource_idx",
    "upload_jobs_state_expiry_idx",
    "rate_limit_buckets_expiry_idx",
    "repositories_single_official_idx",
    "apps_catalog_name_idx",
    "apps_catalog_category_name_idx",
    "apps_catalog_repository_name_idx",
    "apps_catalog_updated_idx",
    "apps_catalog_newest_idx",
    "versions_published_app_date_idx",
    "featured_active_order_idx",
    "featured_section_app_unique_idx",
}


def validate() -> None:
    connection = sqlite3.connect(":memory:")
    connection.execute("PRAGMA foreign_keys = ON")
    migration_files = sorted(MIGRATIONS.glob("*.sql"))
    if not migration_files:
        raise RuntimeError("No D1 migrations were found.")

    for migration in migration_files:
        connection.executescript(migration.read_text(encoding="utf-8"))

    actual_tables = {
        row[0]
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        )
    }
    if missing := EXPECTED_TABLES - actual_tables:
        raise RuntimeError(f"Missing expected tables: {', '.join(sorted(missing))}")

    actual_indexes = {
        row[0]
        for row in connection.execute("SELECT name FROM sqlite_master WHERE type = 'index'")
    }
    if missing := EXPECTED_INDEXES - actual_indexes:
        raise RuntimeError(f"Missing expected indexes: {', '.join(sorted(missing))}")

    category_names = {
        row[0] for row in connection.execute("SELECT name FROM categories ORDER BY ordinal")
    }
    if len(category_names) != 9:
        raise RuntimeError(f"Expected 9 canonical categories, found {len(category_names)}.")

    session_columns = {
        row[1] for row in connection.execute("PRAGMA table_info(admin_sessions)")
    }
    if "token" in session_columns or "password" in session_columns:
        raise RuntimeError("Admin session metadata must not persist bearer tokens or passwords.")

    connection.execute("INSERT INTO developers (id, name) VALUES ('test-developer', 'Authorized Test Publisher')")
    connection.execute(
        "INSERT INTO repositories (id, identifier, name, manifest_url, trust_level) "
        "VALUES ('test-repository', 'org.example.test', 'Test Repository', "
        "'https://repo.example.invalid/index.json', 'user-confirmed')"
    )
    connection.execute(
        "INSERT INTO apps (id, bundle_identifier, name, developer_id, category_id, description, "
        "icon_object_key, repository_id) VALUES ('test-app', 'org.example.app', 'Test App', "
        "'test-developer', 'utilities', 'Migration constraint fixture.', 'icons/test-app.png', 'test-repository')"
    )
    try:
        connection.execute(
            "INSERT INTO versions (id, app_id, version, build, minimum_ios, ipa_object_key, sha256, size) "
            "VALUES ('bad-release', 'test-app', '1.0.0', '1', '16.0', 'packages/bad.ipa', 'invalid', 1)"
        )
    except sqlite3.IntegrityError:
        pass
    else:
        raise RuntimeError("The versions table accepted an invalid SHA-256 digest.")

    try:
        connection.execute(
            "INSERT INTO versions (id, app_id, version, build, minimum_ios, ipa_object_key, sha256, size) "
            "VALUES ('oversized-release', 'test-app', '1.0.0', '1', '16.0', 'packages/large.ipa', "
            "'0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef', 4294967297)"
        )
    except sqlite3.IntegrityError:
        pass
    else:
        raise RuntimeError("The versions table accepted a package over its declared maximum size.")

    foreign_key_issues = list(connection.execute("PRAGMA foreign_key_check"))
    if foreign_key_issues:
        raise RuntimeError(f"Foreign key check failed: {foreign_key_issues!r}")

    try:
        connection.execute(
            "INSERT INTO apps (id, bundle_identifier, name, developer_id, category_id, description, "
            "icon_object_key, repository_id) VALUES ('missing-fk-app', 'org.example.missing-fk', 'Bad FK', "
            "'missing-developer', 'utilities', 'Must fail on foreign key.', 'icons/bad.png', 'test-repository')"
        )
    except sqlite3.IntegrityError:
        pass
    else:
        raise RuntimeError("The apps table accepted a missing developer foreign key.")

    try:
        connection.execute(
            "INSERT INTO apps (id, bundle_identifier, name, developer_id, category_id, description, "
            "icon_object_key, repository_id, published) VALUES ('no-release', 'org.example.no-release', "
            "'No Release', 'test-developer', 'utilities', 'Must stay private.', "
            "'icons/no-release.png', 'test-repository', 1)"
        )
    except sqlite3.IntegrityError:
        pass
    else:
        raise RuntimeError("The schema accepted a published app without a published release.")

    connection.executescript((ROOT / "backend" / "seeds" / "dev.sql").read_text(encoding="utf-8"))
    public_apps = connection.execute(
        "SELECT COUNT(*) FROM apps a WHERE a.published = 1 AND a.deleted_at IS NULL "
        "AND EXISTS (SELECT 1 FROM versions v WHERE v.app_id = a.id AND v.published_at IS NOT NULL)"
    ).fetchone()[0]
    if public_apps != 4:
        raise RuntimeError(f"Expected four published development apps, found {public_apps}.")

    search_results = connection.execute(
        "SELECT app_id FROM app_search WHERE app_search MATCH ?", ('"aurora"*',)
    ).fetchall()
    if [row[0] for row in search_results] != ["app-aurora-notes"]:
        raise RuntimeError("The FTS5 catalog search index was not populated by the seed data.")

    hidden_search_results = connection.execute(
        "SELECT COUNT(*) FROM app_search WHERE app_id = 'app-hidden-demo'"
    ).fetchone()[0]
    if hidden_search_results:
        raise RuntimeError("The FTS5 index exposed an unpublished app.")

    connection.close()


def validate_existing_search_backfill() -> None:
    migrations = sorted(MIGRATIONS.glob("*.sql"))
    if len(migrations) < 2:
        raise RuntimeError("The public-catalog migration is missing.")

    connection = sqlite3.connect(":memory:")
    connection.execute("PRAGMA foreign_keys = ON")
    connection.executescript(migrations[0].read_text(encoding="utf-8"))
    connection.execute("INSERT INTO developers (id, name) VALUES ('legacy-dev', 'Legacy Publisher')")
    connection.execute(
        "INSERT INTO repositories (id, identifier, name, manifest_url, trust_level) "
        "VALUES ('legacy-repo', 'org.example.legacy', 'Legacy Repository', "
        "'https://repo.example.invalid/legacy.json', 'official')"
    )
    connection.execute(
        "INSERT INTO apps (id, bundle_identifier, name, developer_id, category_id, description, "
        "icon_object_key, repository_id, published) VALUES ('legacy-app', 'org.example.legacyapp', "
        "'Legacy Searchable App', 'legacy-dev', 'utilities', 'Existing catalog record.', "
        "'icons/legacy.png', 'legacy-repo', 1)"
    )
    connection.execute(
        "INSERT INTO versions (id, app_id, version, build, minimum_ios, ipa_object_key, sha256, size, published_at) "
        "VALUES ('legacy-release', 'legacy-app', '1.0.0', '1', '16.0', 'packages/legacy.ipa', "
        "'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 1, '2026-01-01T00:00:00.000Z')"
    )
    connection.executescript(migrations[1].read_text(encoding="utf-8"))
    indexed = connection.execute(
        "SELECT app_id FROM app_search WHERE app_search MATCH ?", ('"legacy"*',)
    ).fetchall()
    if indexed != [("legacy-app",)]:
        raise RuntimeError("The catalog FTS migration did not backfill an existing published app.")
    connection.close()


if __name__ == "__main__":
    validate()
    validate_existing_search_backfill()
    print("D1 migrations: schema and integrity checks passed.")
