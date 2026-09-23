# BanG Dream official live-event audit — 2026-09-22

## Result

The official site's newest live-event order is the publication order of its public WordPress `events` custom post type, filtered to the official `ライブ` taxonomy term:

```text
GET https://bang-dream.com/wp-json/wp/v2/events
    ?tax_events=51
    &per_page=41
    &orderby=date
    &order=desc
    &_fields=id,date,modified,slug,link,title,tax_events
```

`tax_events=51` is the site's own `ライブ` term. The public response reported 223 live records. The captured response order is preserved; it is not re-sorted by event date, modification date, numeric ID, or title.

The visible `/events/` archive cannot establish publication order. It is ordered primarily by displayed event date and mixes `ライブ` and `イベント`: its first three records were the March 2027 event “みやこのアトリエ,” the 2027 Roselia tour, and January 2027 “eleganza.” The publication feed instead starts with “eleganza” (published 2026-09-22), the Roselia tour, then WONDERLIVET 2026. `archive-event-date-order.json` preserves this contrast.

The first 40 publication rows contain 39 unique current live pages. Publication ranks 27 and 28 are separate historical DAY1/DAY2 URLs for BanG Dream! Special LIVE in TAIPEI, but both now serve the same merged two-day HTML byte-for-byte (SHA-256 `b29a2a6df25a44501b123c2658d31f52d9e811b8752afd7434cc1fb6ecff29d2`). Publication rank 41, Morfonica 5th Anniversary LIVE「Maestoso」, supplies unique-live rank 40.

Therefore the deduplicated newest-40 set is `unique-40-manifest.json`: publication ranks 1–27, rank 29–40, and rank 41. The original 40-publication replay remains in `manifest.json` for the stable baseline.

## Independent evidence

- `events-publication-order.json` — original live-only 40-row API response.
- `events-publication-order-41.json` — 41-row response used to obtain 40 unique live pages.
- `events-publication-order.headers` — response headers, including `X-WP-Total: 223`.
- `event-taxonomy-terms.json` and `wordpress-taxonomies.json` — official taxonomy identity and term counts.
- `events-index.html` and `archive-event-date-order.json` — current visible archive and extracted event-date sequence.
- `html/` — current normal public HTML. Only paths referenced by a manifest are audit inputs; several non-live discovery pages remain cached but are excluded.
- `ground-truth.json` — independent raw extraction from official HTML, with CSS locators, raw schedule/venue/performer/price text, ticket rounds, links, page images, event-goods-only images, byte counts, and SHA-256 hashes.
- `normalized-expected.json` — hand-reviewed expectations for the original 40 publication rows.
- `supplemental-normalized-expected.json` — hand-reviewed expectations for publication rank 41.
- `unique-40-normalized-expected.json` — the deduplicated newest-40 expectations.

The normalized records assert actual HTML titles, performance/session count, local dates, known door/start times, per-date venues, time zones, expected performer inclusions, performers that must not leak onto the wrong festival day, ticket tier names, ISO currency and minor units, ticket-round names, and images found only inside official goods/merchandise sections. Additional official cast/member lines are allowed. Generic synthetic day labels and full-width versus ASCII parentheses are not treated as semantic failures. WordPress thumbnail suffixes are canonicalized when comparing the same underlying image.

Foreign prices use currency minor units: for example `NT$5,880` is `588000 TWD` minor units and `HK$1,688` is `168800 HKD` minor units. JPY has zero decimal minor units.

Third-party festival pages often publish dates, venues, and BanG Dream appearance details without ticket prices or ticket rounds. Empty expected ticket arrays on those pages mean the official BanG Dream page did not publish those facts; no values were inferred from external promoters.

## Parser verification

The production Swift parser was run against the captured HTML, independent of the extractor used to establish expectations:

- Original 40 publication rows: 40 fetched, 0 parser failures, 40/40 matched all asserted normalized fields.
- Deduplicated newest 40 live pages: 40 fetched, 0 parser failures, 40/40 matched all asserted normalized fields.
- Supplemental rank 41 page: fetched and parsed with 0 parser failures; its normalized performance, three venue ticket tiers, stream price, and five goods-section images were verified.

The final comparison files are `mismatches-app-after.json` and `unique-40-mismatches.json`; both contain zero semantic mismatches. `compare-normalized.mjs` is reusable against a later parser output. `extract-ground-truth.mjs` and `build-normalized-expected.mjs` reproduce the evidence and expected-data artifacts without invoking the app parser.

## Access note

The audit used the app's normal public request headers:

```text
User-Agent: LiveDashboard-iOS/1.0 (+official public event refresh)
Accept-Language: ja,en;q=0.5
```

With those headers the public archive, REST endpoints, and all selected detail pages returned normal successful responses. Earlier anonymous/default curl requests intermittently saw a cached 404 for the bare archive while paginated and filtered URLs stayed available; this did not affect the captured app-header responses.
