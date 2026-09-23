# LoveLive official-source audit — 2026-09-22

Follow-up: the request-header cause has been identified and repaired for HTML and images. See [403 fix and verification](403-fix.md). The results below describe the original audit; its failed responses remain preserved.

## Result

The LoveLive origin returned HTTP 403 with a 12,395-byte HTML response to the app-style command-line request used for this audit, including on all current live indexes and the series NEWS index. The same public pages loaded normally in the Codex in-app browser without authentication, a challenge, or a bypass. This difference is material to the app audit: browser reachability does not establish that the app's `URLSession` ingestion path can fetch the pages.

Twenty current official detail pages were inspected through the normal browser. `current-event-facts.json` records browser-visible official facts and explicitly marks missing fields. `replay-manifest.json` lists those URLs. Its paths were empty during the original blocked audit; after the request-header repair they now point to real captured official HTML, with hashes in `capture-after-403-fix.json`.

The independent audit CLI was then run against all 20 manifest URLs with real network access. All 20 returned `OfficialScrapeFailure.invalidResponse` with `HTTP 403`; `live-audit-result.json` preserves the machine-readable result. This confirms that the app-style live fetch is blocked before parsing, while normal browser navigation succeeds.

## Ordering

`publication-order-evidence.json` preserves the official series NEWS `ライブ/イベント` card order for pages 1–6. The cards were visibly sorted by publication date descending. Updates that clearly named the same event were collapsed to the event's latest encountered publication.

That dated list is not identical to the branch live indexes. Several current index entries—such as Liella! 8th LoveLive Tour, Ikizulive 3rd LIVE, the 103/106 Link Live Dream pages, and the current Aqours branch entries—did not appear in the inspected aggregate NEWS window. Their order is only verified within their respective official branch indexes, which expose no publication timestamp. They must not be inserted into an absolute cross-branch publication order based on performance date, URL number, or image path.

## Current branch indexes inspected

- <https://www.lovelive-anime.jp/hasunosora/live-event/>
- <https://www.lovelive-anime.jp/yuigaoka/live/>
- <https://www.lovelive-anime.jp/lovehigh/live/>
- <https://www.lovelive-anime.jp/nijigasaki/live.php>
- <https://www.lovelive-anime.jp/uranohoshi/live.php>
- <https://www.lovelive-anime.jp/news/?subcategory=event&page=1>

## Important data findings

- Event, ticket, streaming, and goods lifecycles are independent. Finished events still expose streaming, after-sales, or fulfillment information.
- Prices must retain their kind. U-20 prices and upgrade differences are not base admission prices; streaming and VRChat prices are distinct from venue tickets.
- Cast scope can vary by day or stop. Examples include LL02, LL03, LL09, LL12, LL13, LL16, and LL20.
- Tour stage names, cities, and dates are separate scopes. LL12 and LL19 cannot be flattened to one venue or one cast rule.
- Goods images on a detail page are not all key visuals. The JSON keeps only one representative candidate and does not assign semantic image kinds without a visible label.
- Query parameters `p` and `_id` are event identity and must be retained.

## Known gaps

- The current browser tab did not expose all hidden sections at once. Ticket and goods section existence and links were recorded, but round dates are null unless visible text gave the exact dates.
- LL01's current page showed a dated `2026.09.04 up` general-lottery update and section headings, while its detailed schedule/cast tab did not remain available in the later browser read. Its index-confirmed dates and venue are recorded; current cast, prices, and per-day times remain unverified.
- A current official publication date is unavailable for several branch-only detail pages. The audit does not infer it from event date or asset path.
- No raw current HTML is saved, so the current browser facts are evidence for the audit report, not replay fixtures.
