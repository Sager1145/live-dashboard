# Source and ingestion report

Report date: 2026-09-22. The research manifest is not production data. All registry entries remain `enabled: false` and `reviewStatus: pending_review` until the operator records robots, terms, access, and reuse decisions. A successful fixture parse is evidence of a template at the captured time; it is not permission to fetch or publish.

## Captured template evidence

The repository contains 19 template snapshots plus 17 bounded research snapshots captured on 2026-09-22. Their provenance is recorded in `server/tests/fixtures/snapshots/MANIFEST.md` and `docs/SOURCE_ACCESS_REPORT.md`. The implemented adapters use selectors observed in those exact files:

- BanG Dream event index, one unrelated single-performance detail (`mygo-avemujica2026`), the exact BD01 hub plus three linked day details, and the exact primary pages for BD02-BD10. The hub explicitly states all three BD01 dates/times, venue, and per-day performers; each day detail yields typed, source-bounded ticket rounds and a typed advance-online-sales goods campaign. The exact BD02-BD10 primary schedule and venue blocks have regression assertions, including the four explicit BD05 tour stops and both BD07 final days. BD09's saved page does not expose a complete primary schedule or venue in the verified template, so it emits neither.
- The captured BD01 e+ detail yields seven typed ticket rounds from three explicit `DAY` article blocks. Each round retains its enclosing day label and is mapped to a caller-supplied performance ID when available; the adapter never combines tickets across day blocks.
- Bushiroad live-goods index plus two blog article shells. Both article bodies are empty and use a JavaScript redirect to a `/pages/` page. The parser reports `redirect_shell` for those shells. Separately captured final `/pages/` pages for BD01 and BD07 yield typed online campaigns and visible product-card prices. BD01 keeps its general and separately timed happi campaigns distinct and links each product by a stable source key.
- The saved BD08 page yields one explicit ¥5,500 e+ streaming offer, its sales/archive windows, official ticket resale, identity-document requirements as raw qualification text, and two venue-goods sessions. The saved BD10 page yields official resale, raw qualification text, and separate main-goods/capsule venue sessions. These extractors stay within their named source sections.
- The saved TACHIKAWA STAGE GARDEN page independently confirms BD03's single performance, venue, and six ticket tiers.
- Love Live news, Aqours/Nijigasaki/Liella!/Hasunosora/Lovehigh branch indexes, the LL01 `15th_lovelivefest` detail, the official store portal, legacy migration page, and School idol STORE home page.

The LL01 detail fixture supports two structured performance schedules, venue text, ticket price candidates, ten typed ticket rounds, a typed advance-sales goods campaign, eight structured cast groups/roles, and event seating/goods images. Its two upgrade iterations have distinct source keys and evidence locators. The direct after-pamphlet product capture adds a typed post-event sales window, ¥8,000 price, two-item order limit, and shipping note. Its performer section does not label Day.1 versus Day.2, so cast applicability remains unresolved instead of being assigned to both days. Every candidate carries the snapshot ID, DOM locator, raw evidence, section path, source language, parser version, and unresolved applicability unless the source states scope and the caller supplies known performance IDs.

The LL03, LL08, and LL10 School idol STORE collection captures provide bounded sales/shipping campaigns and 13, 11, and 19 visible product cards respectively. Product and variant source keys come from captured Shopify metadata, while every published amount is also present on its visible card. The captured T-shirt products expose three named variants at ¥3,500. Product images are classified as `product`, rather than as whole-campaign goods lists.

## Research-candidate status

`discovered in saved index` means only that a saved official branch/list page links to the candidate. `detail fixture` means the exact event detail was saved and parsed. No row below is approved for automatic publication.

| ID | Current evidence | Missing before publication |
|---|---|---|
| BD01 | Exact official hub, three day details, e+ detail, and final Bushiroad `/pages/` goods page saved; schedules/performers, typed day tickets, two timed goods campaigns, and 84 priced product cards parse | Independent identity/scope/field review and uncaptured individual product-detail attributes |
| BD02 | Exact primary MyGO!!!!! page saved and regression-classified | Kobe edition and streaming page; edition relationship review |
| BD03 | Exact primary event and venue pages saved; single schedule, venue, six tiers, and primary event fields parse | Final goods page and independent field review |
| BD04 | Exact event detail saved and regression-classified | Independent field review |
| BD05 | Exact tour page saved; four explicitly named stop dates/venues parse | Anniversary hub and reviewed stop identity mapping |
| BD06 | Exact event page saved and regression-classified; goods link visible in saved Bushiroad index | Licensed-goods evidence and entity separation |
| BD07 | Exact tour-final page and final Bushiroad goods page saved; both final-day schedules, online campaign, and 85 priced product cards parse | Taipei stop/ticket pages; Taiwan scope/timezone/currency and independent product review |
| BD08 | Exact Tokyo page saved; primary schedule/venue, ¥5,500 streaming offer, resale, raw qualification text, and venue-goods sessions parse | Hyogo page and stop relationship review |
| BD09 | Exact mixed-event tour page saved and regression-classified | Both Spin Up details; activity-type review |
| BD10 | Exact event page saved; primary schedule/venue, resale, raw qualification text, and two venue-sales sessions parse | Reviewed mapping of release eligibility to a ticket round and independent field review |
| LL01 | Exact official detail and after-pamphlet product saved; typed rounds/goods/cast plus product price/window/limit extracted | Independent day-scope/field review |
| LL02 | Discovered in saved official branch indexes; exact detail GET returned generic HTTP 403 and no bypass was attempted | Accessible exact detail and performer/agency sources; film/on-stage role review |
| LL03 | Discovered in saved Hasunosora index; exact detail GET returned generic HTTP 403; official goods collection saved with campaign and 13 priced products | Accessible exact event detail; per-day eligibility scope and product-detail attributes |
| LL04 | Discovered in saved Hasunosora index; exact detail GET returned generic HTTP 403 and no bypass was attempted | Accessible exact detail; U20/tier review |
| LL05 | Discovered in saved Hasunosora index; exact detail GET returned generic HTTP 403 and no bypass was attempted | Accessible exact detail and CD page; per-day guest/eligibility scope |
| LL06 | Discovered in saved Liella index; exact detail GET returned generic HTTP 403 and no bypass was attempted | Accessible tour detail, both news pages, and album product; stop/day mapping |
| LL07 | Discovered with `_id=3rdLIVE` in saved Lovehigh index; exact detail GET returned generic HTTP 403 and no bypass was attempted | Accessible exact detail and e+ page; ticket-round separation |
| LL08 | Discovered with `_id=2ndLIVE` in saved Lovehigh index; exact detail GET returned generic HTTP 403; official goods collection saved with campaign and 11 priced products | Accessible exact event detail and onsite-bonus news; product-detail attributes |
| LL09 | Discovered in saved Nijigasaki index; exact detail GET returned generic HTTP 403 and no bypass was attempted | Accessible exact detail, streaming, and campaign news; stop/day/archive separation |
| LL10 | Discovered in saved Hasunosora index; exact detail GET returned generic HTTP 403; official after-goods collection saved with campaign and 19 priced products | Accessible exact event detail and Blu-ray news; stage/variant shipping scope and product-detail attributes |

## Network and failure behavior

`fetchDocument` rejects disabled or unreviewed sources before DNS. For approved policies it requires HTTPS, exact host, explicit path prefix, allowed method/port/content type, public DNS answers, and a TLS connection pinned to a validated address. It repeats validation for every redirect, caps redirects and decompressed bytes, validates HTML content, and treats login/CAPTCHA/access-denied shells as blocked.

Conditional requests use only origin-provided `ETag` and `Last-Modified`. A 304 returns the previous snapshot. A 401/403 stops automatic retries, a 429 exposes `Retry-After`, and a 404/410 or retryable failure retains `lastKnownSnapshot`. Raw and normalized SHA-256 hashes are stored separately.

## Known gaps

- Robots and terms decisions are not yet recorded as approved for any origin.
- A one-time check of `https://bang-dream.com/robots.txt` returned HTTP 200 and did not list the captured BD01 public paths as disallowed. Terms and reuse remain pending, so the registry remains disabled.
- No Playwright adapter, PDF parser, or release adapter is implemented. The venue adapter is deliberately limited to the captured TACHIKAWA STAGE GARDEN template, and the e+ adapter to the captured `/sf/detail/` ticket-article template.
- Collection pages do not expose reviewed per-variant inventory or variant-specific images; product-card availability remains a product-level candidate; variant availability is left unset and product-detail-only attributes remain unsupported. Purchase limits are extracted only from the LL01 direct product page where the exact text is present.
- BD08 is the only saved page with a supported explicit stream-offer section. Qualification requirements on BD08/BD10 remain source-bounded raw text until an administrator maps them to a reviewed ticket policy or round. The malformed overseas archive wording outside the supported time block is not normalized.
- BD09's captured mixed-tour page does not expose a complete primary schedule or venue in the verified selectors. It stays classified with explicit missing typed fields instead of borrowing dates from linked event pages.
- Encoding is currently decoded as UTF-8 after retaining raw bytes. All saved fixtures declare UTF-8; additional encodings require a reviewed decoder before enabling those sources.
- The detail adapters create candidate facts only. Identity reconciliation, schema validation, review, publication, and stable UUID assignment stay outside ingestion.
