CREATE TABLE app_settings(
  key text PRIMARY KEY,
  value jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO app_settings(key,value) VALUES('scraping_enabled','true'::jsonb);
