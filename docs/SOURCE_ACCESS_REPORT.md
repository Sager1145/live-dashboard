# Source access report

Research observation date: **2026-09-22**

This report records a bounded access check for the exact primary event-detail URLs in `fixtures/sources-manifest.json`: BD02–BD10 and LL02–LL10, plus the manifest's BD01 e+ ticket URL. It does not validate event facts, approve a source's terms, authorize scheduled collection, or turn these research captures into production data.

## Method

- One ordinary public `GET` was made to each exact URL. No list crawl, URL guessing, authentication, browser automation, challenge bypass, or retry through an alternate route was used.
- Redirects, if returned, were followed with a limit of five. Every recorded final URL remained the requested URL.
- Requests used `LiveDashboardSourceAudit/0.1 (research; ordinary public GET)` and accepted normal compression.
- A response body was saved under `server/tests/fixtures/research/` only when the response was HTTP 200 HTML and its title/content matched the requested page.
- SHA-256 values cover the decoded response bytes saved or observed. Capture timestamps are response-file completion times in UTC.
- `robots.txt` was requested once per distinct host as an observation only. Robots output is neither permission nor a terms review, and no scheduler/source was enabled by this work.

## Result

Ten pages were accessible as normal matching HTML: the nine BanG Dream primary pages and the BD01 e+ page. Nine Love Live pages returned HTTP 403 with the same generic `NOT FOUND` response. The 403 bodies were not stored as regression fixtures, and no bypass was attempted.

| ID | Exact requested URL / final URL | HTTP | Content-Type | Bytes | Captured UTC | SHA-256 | Saved fixture / error |
|---|---|---:|---|---:|---|---|---|
| BD01 e+ | `https://eplus.jp/sf/detail/4529430001` | 200 | `text/html;charset=UTF-8` | 66,146 | 2026-09-22T18:00:50Z | `9a3a68f15a734d13c6a9bfef735e5b1c11396e2433361d67da0bf25370cff323` | `BD01-eplus.html`; title and canonical URL identify BanG Dream! 13th☆LIVE |
| BD02 | `https://bang-dream.com/events/mygo_9th/` | 200 | `text/html; charset=UTF-8` | 95,596 | 2026-09-22T18:00:35Z | `784e362630e8e2c8aa7336f9db6d31156d39a8b2be29cde1e498ec5595ef073d` | `BD02.html` |
| BD03 | `https://bang-dream.com/events/morfonica_live_2026/` | 200 | `text/html; charset=UTF-8` | 84,973 | 2026-09-22T18:00:36Z | `54f58fa01a4200135ae878fd555d5732e602f587ba9cea3302bd61082638a8ca` | `BD03.html` |
| BD04 | `https://bang-dream.com/events/eleganza/` | 200 | `text/html; charset=UTF-8` | 58,239 | 2026-09-22T18:00:37Z | `89f0aea29a6c1bfb558a542d92109a1eb2d05b4b1bd114264ada7e8f7556dddf` | `BD04.html` |
| BD05 | `https://bang-dream.com/events/roselia-10th-anniversary-live-tour/` | 200 | `text/html; charset=UTF-8` | 34,210 | 2026-09-22T18:00:38Z | `7568693507d7015c9c9aa68c472e3a4f5a2564ee2dbd6babd9e75446b6af02fd` | `BD05.html` |
| BD06 | `https://bang-dream.com/events/lehre-der-rose/` | 200 | `text/html; charset=UTF-8` | 100,466 | 2026-09-22T18:00:39Z | `98261f7b4b8b55d57bb6c7af0b897fa3c03ea25c92a830db0ba8c75b9faa1d66` | `BD06.html` |
| BD07 | `https://bang-dream.com/avemujica_livetour_final/` | 200 | `text/html; charset=UTF-8` | 83,084 | 2026-09-22T18:00:40Z | `36643e8def2e6dcb874d5e7389f1b03899b9a26ba7df1e2e52ce75e20d586e0b` | `BD07.html` |
| BD08 | `https://bang-dream.com/ras_2026_tokyo/` | 200 | `text/html; charset=UTF-8` | 80,914 | 2026-09-22T18:00:41Z | `9776ff7c1389aba5df78072b143e21f5b3a0bef02c20dfa76d5746e8a6675d62` | `BD08.html` |
| BD09 | `https://bang-dream.com/yumemita_superposition/` | 200 | `text/html; charset=UTF-8` | 38,006 | 2026-09-22T18:00:42Z | `33aa6cd69b7a2fcae19653fff619cfa344a20c3909f32714d5812c675d6cb85b` | `BD09.html` |
| BD10 | `https://bang-dream.com/events/ppp-roselia2026/` | 200 | `text/html; charset=UTF-8` | 85,625 | 2026-09-22T18:00:43Z | `39e94957814fb7a698392724797f76bde4b01be42fa511a6e587cb808fc74393` | `BD10.html` |
| LL02 | `https://www.lovelive-anime.jp/special/live/live_detail.php?p=15thzenyasai` | 403 | `text/html` | 12,395 | 2026-09-22T18:00:43Z | `00503c4ef4154d8cd93bfb07b27fe33aa126174cb2fc7ebd06db002ddb0a883b` | Not saved: generic `NOT FOUND` response; no bypass |
| LL03 | `https://www.lovelive-anime.jp/hasunosora/live-event/live_detail.php?p=LLDream` | 403 | `text/html` | 12,395 | 2026-09-22T18:00:44Z | `00503c4ef4154d8cd93bfb07b27fe33aa126174cb2fc7ebd06db002ddb0a883b` | Not saved: generic `NOT FOUND` response; no bypass |
| LL04 | `https://www.lovelive-anime.jp/hasunosora/live-event/live_detail.php?p=LLDream106` | 403 | `text/html` | 12,395 | 2026-09-22T18:00:44Z | `00503c4ef4154d8cd93bfb07b27fe33aa126174cb2fc7ebd06db002ddb0a883b` | Not saved: generic `NOT FOUND` response; no bypass |
| LL05 | `https://www.lovelive-anime.jp/hasunosora/live-event/live_detail.php?p=LLDream103` | 403 | `text/html` | 12,395 | 2026-09-22T18:00:45Z | `00503c4ef4154d8cd93bfb07b27fe33aa126174cb2fc7ebd06db002ddb0a883b` | Not saved: generic `NOT FOUND` response; no bypass |
| LL06 | `https://www.lovelive-anime.jp/yuigaoka/live/live_detail.php?p=8thlivetour` | 403 | `text/html` | 12,395 | 2026-09-22T18:00:46Z | `00503c4ef4154d8cd93bfb07b27fe33aa126174cb2fc7ebd06db002ddb0a883b` | Not saved: generic `NOT FOUND` response; no bypass |
| LL07 | `https://www.lovelive-anime.jp/lovehigh/live/live_detail.php?_id=3rdLIVE` | 403 | `text/html` | 12,395 | 2026-09-22T18:00:46Z | `00503c4ef4154d8cd93bfb07b27fe33aa126174cb2fc7ebd06db002ddb0a883b` | Not saved: generic `NOT FOUND` response; no bypass |
| LL08 | `https://www.lovelive-anime.jp/lovehigh/live/live_detail.php?_id=2ndLIVE` | 403 | `text/html` | 12,395 | 2026-09-22T18:00:47Z | `00503c4ef4154d8cd93bfb07b27fe33aa126174cb2fc7ebd06db002ddb0a883b` | Not saved: generic `NOT FOUND` response; no bypass |
| LL09 | `https://www.lovelive-anime.jp/nijigasaki/live/live_detail.php?p=8thlive` | 403 | `text/html` | 12,395 | 2026-09-22T18:00:47Z | `00503c4ef4154d8cd93bfb07b27fe33aa126174cb2fc7ebd06db002ddb0a883b` | Not saved: generic `NOT FOUND` response; no bypass |
| LL10 | `https://www.lovelive-anime.jp/hasunosora/live-event/live_detail.php?p=6thBGP` | 403 | `text/html` | 12,395 | 2026-09-22T18:00:48Z | `00503c4ef4154d8cd93bfb07b27fe33aa126174cb2fc7ebd06db002ddb0a883b` | Not saved: generic `NOT FOUND` response; no bypass |

The matching 200 page titles were checked before saving. The response text for the e+ page contains incidental `404` strings in site markup, but its HTTP status, title, canonical URL, description, breadcrumb, and heading all identify the requested BanG Dream! 13th☆LIVE ticket page.

## Robots observations

| Host | Exact URL / final URL | HTTP | Content-Type | Bytes | Captured UTC | SHA-256 | Observation |
|---|---|---:|---|---:|---|---|---|
| `bang-dream.com` | `https://bang-dream.com/robots.txt` | 200 | `text/plain; charset=utf-8` | 116 | 2026-09-22T18:00:51Z | `236fdd41d132b6b97537e2ca5c96496318fef7b7fffdeae827a378bae44a29d2` | Declares `Disallow: /wordpress/wp-admin/`, allows its `admin-ajax.php`, and lists a sitemap. This observation does not approve collection. |
| `www.lovelive-anime.jp` | `https://www.lovelive-anime.jp/robots.txt` | 403 | `text/html` | 12,395 | 2026-09-22T18:00:51Z | `00503c4ef4154d8cd93bfb07b27fe33aa126174cb2fc7ebd06db002ddb0a883b` | Same generic `NOT FOUND` response as the detail URLs. Robots policy remains unverified; no retry or bypass was attempted. |
| `eplus.jp` | `https://eplus.jp/robots.txt` | 200 | `text/plain` | 551 | 2026-09-22T18:00:52Z | `231a5ad4143edb1a53d8d70452dc385fdde06c4dba547995f4595ab6ee24c8cb` | Lists several `/sf/` search/block exclusions and sitemaps. This observation does not approve collection or reuse. |

## Use of captures

The ten saved pages are immutable research fixtures for adapter regression work. They remain `not_production_data`: selectors, extracted facts, applicability, publication state, source policy, and image use still require separate validation. The nine 403 results must remain `blocked`/access observations and must not be interpreted as event cancellation, page removal, missing official information, or permission to use a bypass.

## Goods, product, collection, and venue follow-up

A second bounded check covered seven exact supporting URLs. The two Bushiroad Store `/pages/` URLs were copied literally from `window.location.replace(...)` values in the existing redirect fixtures; their JavaScript was not executed and no alternate URL was guessed. The Love Live product and collection URLs and the BD03 venue URL were supplied by the research manifest/seed set. Each exact URL received one ordinary public `GET` using the same request settings and validation rules described above. All seven returned HTTP 200 matching HTML, and every final URL remained the requested URL.

| ID | Exact requested URL / final URL | HTTP | Content-Type | Bytes | Captured UTC | SHA-256 | Saved fixture |
|---|---|---:|---|---:|---|---|---|
| BD01 goods | `https://bushiroad-store.com/pages/bd_13th-live-day1-poppinparty` | 200 | `text/html; charset=utf-8` | 615,730 | 2026-09-22T18:11:38Z | `44ed9ccc73298cfb67bfc71dd15ed25ae13f1d5b98bc76ddae2358d31d2df209` | `BD01-goods-day1.html` |
| BD07 goods | `https://bushiroad-store.com/pages/avemujica_livetour-2026` | 200 | `text/html; charset=utf-8` | 645,248 | 2026-09-22T18:11:39Z | `5667c0909347c366241aef4f51164ec57de345529b38c8866bd24157b02dca62` | `BD07-goods-exitus.html` |
| LL01 product | `https://lovelive.fannect.jp/products/lamd84829` | 200 | `text/html; charset=utf-8` | 124,655 | 2026-09-22T18:11:40Z | `e23969cf3093c4b8cf878e8fd866b20db471980c6260ce7ef1d5041f0d81ab19` | `LL01-after-pamphlet.html` |
| LL03 collection | `https://lovelive.fannect.jp/collections/ll-48-01` | 200 | `text/html; charset=utf-8` | 233,540 | 2026-09-22T18:11:41Z | `9ce4beb15393a1322f1f6da897cda9d19133680b4854aa6e5baad3d28b22c297` | `LL03-goods.html` |
| LL08 collection | `https://lovelive.fannect.jp/collections/ll-47-01` | 200 | `text/html; charset=utf-8` | 224,952 | 2026-09-22T18:11:42Z | `739cc70d713f733c56e0a8d2eca39ca45f2bc31a2b0bff007ef000833bb9168c` | `LL08-goods.html` |
| LL10 collection | `https://lovelive.fannect.jp/collections/ll-43-03` | 200 | `text/html; charset=utf-8` | 262,222 | 2026-09-22T18:11:43Z | `b9c35f3016ae64605104b73592f485eb1b49b61d4becc1c40780e0bd2062f6cf` | `LL10-goods.html` |
| BD03 venue | `https://www.t-sg.jp/events/2026/09/00001502.php` | 200 | `text/html; charset=UTF-8` | 20,758 | 2026-09-22T18:11:45Z | `f735ec3fcdca21aba727ec6e4d632d70c27be2a28a58f5c45fc732a85576cf0f` | `BD03-venue.html` |

The saved titles identify the intended Poppin'Party and Ave Mujica goods pages, the LL01 after-pamphlet product, the LL03/LL08/LL10 event collections, and the Morfonica event at TACHIKAWA STAGE GARDEN. These checks establish only that the exact pages were publicly accessible at capture time.

### Follow-up robots observations

`robots.txt` was requested once for each newly observed host. These are access observations only; they do not approve terms, authorize scheduled collection, or change any workflow's default-disabled origin settings.

| Host | Exact URL / final URL | HTTP | Content-Type | Bytes | Captured UTC | SHA-256 | Observation |
|---|---|---:|---|---:|---|---|---|
| `bushiroad-store.com` | `https://bushiroad-store.com/robots.txt` | 200 | `text/plain; charset=utf-8` | 3,644 | 2026-09-22T18:11:45Z | `21cac475c41aafeeee74a40265e4a5b385db1e9973195e20337be13f9cec8034` | Shopify-generated policy lists transactional, internal, and filter exclusions plus a sitemap. |
| `lovelive.fannect.jp` | `https://lovelive.fannect.jp/robots.txt` | 200 | `text/plain; charset=utf-8` | 3,644 | 2026-09-22T18:11:46Z | `5ebebfadec9affd40ff4d2cf92c5ec15f0be9812e7a72d499457f86dc47d433f` | Shopify-generated policy lists transactional, internal, and filter exclusions plus a sitemap. |
| `www.t-sg.jp` | `https://www.t-sg.jp/robots.txt` | 200 | `text/plain; charset=UTF-8` | 56 | 2026-09-22T18:11:47Z | `5c713bee1efe861e3375968aa3f191f0423a0d38274076fcfc6d8ff70f9b2cf0` | Declares `User-agent: *` and lists the site's sitemap. |

The seven follow-up captures are also immutable research fixtures and remain `not_production_data`. No source registry, ingestion origin, scheduler setting, or published event fact was changed by this work.
