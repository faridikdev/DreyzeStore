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
        "'https://repo.example.invalid/index.json', 'official')"
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

    connection.close()


if __name__ == "__main__":
    validate()
    print("D1 migrations: schema and integrity checks passed.")
