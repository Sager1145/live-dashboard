ALTER TABLE source_snapshots ADD COLUMN IF NOT EXISTS blob_key text;
ALTER TABLE source_snapshots ADD COLUMN IF NOT EXISTS byte_size bigint CHECK(byte_size IS NULL OR byte_size >= 0);

CREATE TABLE media_cache_heads(
  asset_id text PRIMARY KEY,
  original_url text NOT NULL,
  display_policy text NOT NULL CHECK(display_policy IN('link_only','permitted_remote_display','permitted_cache')),
  current_version integer NOT NULL DEFAULT 0 CHECK(current_version >= 0),
  content_hash text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK((current_version = 0 AND content_hash IS NULL) OR (current_version > 0 AND content_hash IS NOT NULL))
);

CREATE TABLE media_versions(
  asset_id text NOT NULL REFERENCES media_cache_heads(asset_id) ON DELETE CASCADE,
  version integer NOT NULL CHECK(version > 0),
  original_url text NOT NULL,
  final_url text NOT NULL,
  content_hash text NOT NULL CHECK(content_hash ~ '^[a-f0-9]{64}$'),
  blob_key text NOT NULL,
  media_type text NOT NULL CHECK(media_type IN('image/png','image/jpeg','image/gif','image/webp','application/pdf')),
  byte_size bigint NOT NULL CHECK(byte_size > 0),
  width integer CHECK(width IS NULL OR width > 0),
  height integer CHECK(height IS NULL OR height > 0),
  response_headers jsonb NOT NULL DEFAULT '{}',
  fetched_at timestamptz NOT NULL,
  PRIMARY KEY(asset_id,version)
);

CREATE INDEX media_versions_content_hash ON media_versions(content_hash);
