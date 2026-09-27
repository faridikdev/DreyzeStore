INSERT OR IGNORE INTO repositories (
  id, identifier, name, manifest_url, trust_level, description, icon_object_key
) VALUES
  ('repo-dreyze-dev', 'com.dreyze.official', 'DreyzeStore Development',
   'https://api.dreyzestore.invalid/api/v1/repository', 'official',
   'Fictional metadata for local API development. No packages are hosted.',
   'icons/repository-dreyze-dev.png'),
  ('repo-community-dev', 'com.dreyze.community', 'Community Metadata Examples',
   'https://community.dreyzestore.invalid/repository.json', 'user-confirmed',
   'Fictional metadata for testing repository filters.',
   'icons/repository-community-dev.png');

INSERT OR IGNORE INTO developers (id, name, website_url) VALUES
  ('developer-dreyze-labs', 'Dreyze Labs (fictional)', 'https://dreyzestore.invalid'),
  ('developer-orbit-workshop', 'Orbit Workshop (fictional)', NULL),
  ('developer-patchwork', 'Patchwork Tools (fictional)', NULL),
  ('developer-glass-garden', 'Glass Garden Studio (fictional)', NULL),
  ('developer-hidden-demo', 'Hidden Demo Publisher (fictional)', NULL);

INSERT OR IGNORE INTO apps (
  id, bundle_identifier, name, developer_id, category_id, description,
  icon_object_key, repository_id, published
) VALUES
  ('app-aurora-notes', 'com.dreyze.auroranotes', 'Aurora Notes', 'developer-dreyze-labs',
   'productivity', 'Fictional sample note-taking app metadata for local catalog development.',
   'icons/aurora-notes.png', 'repo-dreyze-dev', 0),
  ('app-orbit-timer', 'com.dreyze.orbittimer', 'Orbit Timer', 'developer-orbit-workshop',
   'utilities', 'Fictional sample timer app metadata for pagination and version tests.',
   'icons/orbit-timer.png', 'repo-dreyze-dev', 0),
  ('app-patchboard', 'com.dreyze.patchboard', 'Patchboard', 'developer-patchwork',
   'developer-tools', 'Fictional sample developer utility metadata.',
   'icons/patchboard.png', 'repo-dreyze-dev', 0),
  ('app-glass-garden', 'org.example.glassgarden', 'Glass Garden', 'developer-glass-garden',
   'customization', 'Fictional sample customization app metadata from a second repository.',
   'icons/glass-garden.png', 'repo-community-dev', 0),
  ('app-hidden-demo', 'org.example.hiddenapp', 'Hidden Demo App', 'developer-hidden-demo',
   'other', 'Unpublished sample used only to verify public visibility filtering.',
   'icons/hidden-demo.png', 'repo-dreyze-dev', 0);

INSERT OR IGNORE INTO versions (
  id, app_id, version, build, minimum_ios, ipa_object_key, sha256, size,
  release_notes, channel, distribution_rights_attested, published_at
) VALUES
  ('version-aurora-1-0', 'app-aurora-notes', '1.0.0', '1', '16.0',
   'packages/aurora-notes/1.0.0/application.ipa',
   'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 1234567,
   'Fictional development metadata only.', 'stable', 0, strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-20 days')),
  ('version-aurora-1-1', 'app-aurora-notes', '1.1.0', '2', '16.0',
   'packages/aurora-notes/1.1.0/application.ipa',
   'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 1287654,
   'Fictional development metadata only.', 'stable', 0, strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-5 days')),
  ('version-aurora-2-beta', 'app-aurora-notes', '2.0.0-beta.1', '3', '16.0',
   'packages/aurora-notes/2.0.0-beta.1/application.ipa',
   'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc', 1300000,
   'Fictional prerelease metadata only.', 'beta', 0, strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 day')),
  ('version-aurora-unpublished', 'app-aurora-notes', '1.2.0', '4', '16.0',
   'packages/aurora-notes/1.2.0/application.ipa',
   'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd', 1290000,
   'This sample release is not published.', 'stable', 0, NULL),
  ('version-orbit-1-9', 'app-orbit-timer', '1.9.0', '9', '16.0',
   'packages/orbit-timer/1.9.0/application.ipa',
   'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee', 980000,
   'Fictional development metadata only.', 'stable', 0, strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-10 days')),
  ('version-orbit-1-10', 'app-orbit-timer', '1.10.0', '10', '16.0',
   'packages/orbit-timer/1.10.0/application.ipa',
   'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff', 1000000,
   'Fictional development metadata only.', 'stable', 0, strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-2 days')),
  ('version-patchboard-2-beta', 'app-patchboard', '2.0.0-beta.1', '19', '16.0',
   'packages/patchboard/2.0.0-beta.1/application.ipa',
   '1111111111111111111111111111111111111111111111111111111111111111', 2100000,
   'Fictional beta metadata only.', 'beta', 0, strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-4 days')),
  ('version-patchboard-2-stable', 'app-patchboard', '2.0.0', '20', '16.0',
   'packages/patchboard/2.0.0/application.ipa',
   '2222222222222222222222222222222222222222222222222222222222222222', 2150000,
   'Fictional development metadata only.', 'stable', 0, strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-3 days')),
  ('version-glass-garden-1', 'app-glass-garden', '1.0.0', '1', '16.0',
   'packages/glass-garden/1.0.0/application.ipa',
   '3333333333333333333333333333333333333333333333333333333333333333', 750000,
   'Fictional development metadata only.', 'stable', 0, strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-6 days')),
  ('version-hidden-1', 'app-hidden-demo', '1.0.0', '1', '16.0',
   'packages/hidden-demo/1.0.0/application.ipa',
   '4444444444444444444444444444444444444444444444444444444444444444', 800000,
   'Unpublished sample app release.', 'stable', 0, strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 day'));

UPDATE apps
SET published = 1,
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE id IN ('app-aurora-notes', 'app-orbit-timer', 'app-patchboard', 'app-glass-garden');

INSERT OR IGNORE INTO screenshots (id, app_id, object_key, width, height, alt_text, ordinal) VALUES
  ('shot-aurora-1', 'app-aurora-notes', 'screenshots/aurora-notes/overview.png', 1179, 2556,
   'Placeholder metadata for the fictional Aurora Notes app.', 0),
  ('shot-orbit-1', 'app-orbit-timer', 'screenshots/orbit-timer/timer.png', 1179, 2556,
   'Placeholder metadata for the fictional Orbit Timer app.', 0),
  ('shot-patchboard-1', 'app-patchboard', 'screenshots/patchboard/board.png', 1179, 2556,
   'Placeholder metadata for the fictional Patchboard app.', 0);

INSERT OR IGNORE INTO featured (id, section_key, app_id, ordinal, starts_at, ends_at) VALUES
  ('featured-hero-aurora', 'hero', 'app-aurora-notes', 0,
   strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 day'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '+30 days')),
  ('featured-editors-patchboard', 'editors-picks', 'app-patchboard', 0,
   strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 day'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '+30 days')),
  ('featured-editors-orbit', 'editors-picks', 'app-orbit-timer', 1,
   strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 day'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '+30 days')),
  ('featured-new-glass', 'new-releases', 'app-glass-garden', 0,
   strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 day'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '+30 days')),
  ('featured-hidden-demo', 'hero', 'app-hidden-demo', 1,
   strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '-1 day'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now', '+30 days'));
