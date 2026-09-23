DROP INDEX fact_candidate_identity;
CREATE UNIQUE INDEX fact_candidate_identity ON fact_candidates(
 snapshot_id,source_key,kind,
 (evidence->'evidence'->>'locator'),
 (COALESCE(evidence->>'parserVersion','legacy'))
);
