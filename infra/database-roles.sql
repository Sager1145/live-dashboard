-- Run as migration owner. Assign separate LOGIN users to these roles in production.
-- The API hosts the Publisher. Fetch workers cannot modify published facts.
CREATE ROLE livedash_api NOLOGIN;
CREATE ROLE livedash_ingestion NOLOGIN;
CREATE ROLE livedash_notifications NOLOGIN;
GRANT USAGE ON SCHEMA public TO livedash_api,livedash_ingestion,livedash_notifications;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO livedash_api;
GRANT INSERT,UPDATE,DELETE ON events,editions,stops,performances,event_revisions,review_cases,accepted_facts,scoped_records,applicability_members,ticket_offers,catalog_changes,outbox_events,installations,subscriptions,reminders,notification_deliveries,reports,audit_log TO livedash_api;
GRANT UPDATE ON catalog_clock,source_origins,source_documents TO livedash_api;
GRANT SELECT,INSERT,UPDATE,DELETE ON source_origins,source_documents,source_snapshots,source_fetches,entity_aliases,fact_candidates,review_cases,jobs TO livedash_ingestion;
GRANT SELECT ON events,scoped_records TO livedash_ingestion;
GRANT SELECT,INSERT,UPDATE ON media_cache_heads,media_versions TO livedash_ingestion;
GRANT SELECT ON events,performances,subscriptions,reminders,catalog_clock TO livedash_notifications;
GRANT SELECT,UPDATE ON installations,outbox_events TO livedash_notifications;
GRANT SELECT,INSERT,UPDATE,DELETE ON notification_deliveries TO livedash_notifications;
