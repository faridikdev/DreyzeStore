-- Speeds up channel-scoped published-release lookups used by update checks.
-- 0001 already enforces UNIQUE(app_id, version, build), which also prevents
-- duplicate releases across channels; keep that stricter invariant intact.
CREATE INDEX IF NOT EXISTS versions_app_channel_published_idx
  ON versions (app_id, channel, published_at DESC)
  WHERE published_at IS NOT NULL;
