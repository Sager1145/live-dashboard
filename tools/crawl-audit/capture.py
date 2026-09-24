#!/usr/bin/env python3
"""Capture one official page for parser comparison.

Browser capture uses Crawl4AI 0.9.4. Saved HTML can be replayed without a browser.
extracted_content is another parser's output, not an independent answer.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import urllib.error
import urllib.request
from html.parser import HTMLParser
from pathlib import Path

ATTRIBUTION = (
    "This product includes software developed by UncleCode "
    "(https://x.com/unclecode) as part of the Crawl4AI project "
    "(https://github.com/unclecode/crawl4ai)."
)

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/18.0 Safari/605.1.15 LiveDashboardAudit/1.0"
)


class BlockParser(HTMLParser):
    """Keep hidden panes, short text, tables, links, and image candidates."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.blocks: list[dict] = []
        self._pane_stack: list[str | None] = []
        self._heading_stack: list[tuple[int, str, str]] = []
        self._capture: dict | None = None
        self._ignore_depth = 0
        self._in_heading = False
        self._text: list[str] = []
        self._row: list[str] | None = None
        self._cell: list[str] | None = None
        self._anchor: dict | None = None
        self._index = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = {key.lower(): value or "" for key, value in attrs}
        if tag in {"script", "style"}:
            self._ignore_depth += 1
            return
        if self._ignore_depth:
            return
        pane = attributes.get("data-target")
        self._pane_stack.append(pane if pane else None)
        if tag in {"h1", "h2", "h3", "h4", "h5", "h6"}:
            self._close_heading()
            self._in_heading = True
            self._capture = {
                "level": int(tag[1]),
                "title": [],
                "lines": [],
                "tableRows": [],
                "links": [],
                "images": [],
                "pane": next((item for item in reversed(self._pane_stack) if item), None),
            }
            self._text = []
        elif self._capture is not None:
            if tag == "br":
                self._capture["lines"].append(self._take_text())
            elif tag == "tr":
                self._row = []
            elif tag in {"td", "th"} and self._row is not None:
                self._cell = []
            elif tag == "a" and attributes.get("href"):
                self._anchor = {"rawURL": attributes["href"], "label": []}
            elif tag == "img":
                self._capture["images"].extend(image_candidates(attributes))

    def handle_endtag(self, tag: str) -> None:
        if tag in {"script", "style"} and self._ignore_depth:
            self._ignore_depth -= 1
            return
        if self._ignore_depth:
            return
        if self._pane_stack:
            self._pane_stack.pop()
        if self._capture is None:
            return
        if tag in {"td", "th"} and self._cell is not None and self._row is not None:
            self._row.append(clean("".join(self._cell)))
            self._cell = None
        elif tag == "tr" and self._row is not None:
            if any(self._row):
                self._capture["tableRows"].append(self._row)
            self._row = None
        elif tag == "a" and self._anchor is not None:
            label = clean("".join(self._anchor["label"]))
            raw = self._anchor["rawURL"].strip()
            if raw and not raw.lower().startswith("javascript:") and not raw.startswith("#"):
                self._capture["links"].append({"label": label, "rawURL": raw})
            self._anchor = None
        elif tag in {"p", "div", "li"}:
            line = self._take_text()
            if line:
                self._capture["lines"].append(line)
        if tag in {"h1", "h2", "h3", "h4", "h5", "h6"} and self._in_heading and self._capture is not None:
            self._capture["title"] = self._text
            self._text = []
            self._in_heading = False

    def handle_data(self, data: str) -> None:
        if self._ignore_depth or self._capture is None:
            return
        if self._in_heading:
            self._text.append(data)
            return
        if self._cell is not None:
            self._cell.append(data)
        elif self._anchor is not None:
            self._anchor["label"].append(data)
        else:
            self._text.append(data)

    def close(self) -> None:
        self._close_heading()
        super().close()

    def _take_text(self) -> str:
        value = clean("".join(self._text))
        self._text = []
        return value

    def _close_heading(self) -> None:
        capture = self._capture
        if capture is None:
            return
        title = clean("".join(capture["title"]))
        self._capture = None
        self._text = []
        if not title:
            return
        level = capture["level"]
        while self._heading_stack and self._heading_stack[-1][0] >= level:
            self._heading_stack.pop()
        parent = self._heading_stack[-1][1] if self._heading_stack else None
        path = [item[2] for item in self._heading_stack] + [title]
        pane = capture["pane"]
        block_id = f"b{self._index}"
        self._index += 1
        line = self._take_text()
        lines = [item for item in capture["lines"] + ([line] if line else []) if item and item != title]
        self.blocks.append(
            {
                "snapshotID": "",
                "blockID": block_id,
                "parentBlockID": parent,
                "headingPath": path,
                "pane": pane,
                "htmlFragment": "",
                "rawLines": lines,
                "tableRows": capture["tableRows"],
                "links": [
                    {"id": f"{block_id}-link-{index}", "label": link["label"], "rawURL": link["rawURL"], "resolvedURL": None}
                    for index, link in enumerate(capture["links"])
                ],
                "images": [
                    {"id": f"{block_id}-image-{index}", **image}
                    for index, image in enumerate(capture["images"])
                ],
                "locator": (f"pane:{pane}/" if pane else "") + "/".join(path) + f"#{self._index - 1}",
                "scopeHints": path + ([f"pane:{pane}"] if pane else []),
            }
        )
        self._heading_stack.append((level, block_id, title))


def clean(value: str) -> str:
    return " ".join(value.replace("\xa0", " ").split())


def image_candidates(attributes: dict[str, str]) -> list[dict]:
    alt = attributes.get("alt", "")
    found: list[dict] = []
    for source in ("src", "data-src", "data-lazy-src"):
        raw = attributes.get(source, "").strip()
        if raw:
            found.append({"rawURL": raw, "resolvedURL": None, "alt": alt, "source": source})
    for part in attributes.get("srcset", "").split(","):
        raw = part.strip().split(" ")[0] if part.strip() else ""
        if raw:
            found.append({"rawURL": raw, "resolvedURL": None, "alt": alt, "source": "srcset"})
    return found


def blocks_from_html(html: str, snapshot_id: str, page_url: str) -> list[dict]:
    parser = BlockParser()
    parser.feed(html)
    parser.close()
    for block in parser.blocks:
        block["snapshotID"] = snapshot_id
        for link in block["links"]:
            link["resolvedURL"] = resolve_url(link["rawURL"], page_url)
        for image in block["images"]:
            image["resolvedURL"] = resolve_url(image["rawURL"], page_url)
    return parser.blocks


def resolve_url(raw: str, page_url: str) -> str | None:
    from urllib.parse import urljoin

    absolute = urljoin(page_url, raw)
    if absolute.startswith("http://") or absolute.startswith("https://"):
        return absolute
    return None


def fetch_http(url: str, timeout: float) -> tuple[int | None, str | None, str | None]:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "text/html"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            charset = response.headers.get_content_charset() or "utf-8"
            body = response.read().decode(charset, errors="replace")
            return response.status, body, None
    except urllib.error.HTTPError as error:
        detail = f"HTTP {error.code}"
        return error.code, None, detail
    except Exception as error:  # noqa: BLE001 - diagnostics must keep the transport error
        return None, None, str(error)


def write_snapshot(
    out: Path,
    capture_id: str,
    page_url: str,
    transport: str,
    response_html: str | None,
    browser_html: str | None,
    screenshot: bytes | None,
    candidates: object,
    diagnostics: dict,
) -> None:
    out.mkdir(parents=True, exist_ok=True)
    evidence_html = browser_html if browser_html is not None else response_html or ""
    blocks = blocks_from_html(evidence_html, capture_id, page_url)
    acquisition = {
        "captureID": capture_id,
        "url": page_url,
        "transport": transport,
        "representation": "browserDOM" if browser_html is not None else "httpResponse",
        "bodySHA256": hashlib.sha256(evidence_html.encode("utf-8")).hexdigest() if evidence_html else None,
    }
    (out / "acquisition.json").write_text(json.dumps(acquisition, ensure_ascii=False, indent=2), encoding="utf-8")
    if response_html is not None:
        (out / "response.html").write_text(response_html, encoding="utf-8")
    if browser_html is not None:
        (out / "browser-dom.html").write_text(browser_html, encoding="utf-8")
    if screenshot:
        (out / "screenshot.png").write_bytes(screenshot)
    (out / "blocks.json").write_text(json.dumps(blocks, ensure_ascii=False, indent=2), encoding="utf-8")
    (out / "extraction-candidates.json").write_text(
        json.dumps({"note": "Extractor output is not an independent answer.", "candidates": candidates}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    (out / "diagnostics.json").write_text(json.dumps(diagnostics, ensure_ascii=False, indent=2), encoding="utf-8")


def capture_browser(url: str, timeout_ms: int) -> tuple[str | None, bytes | None, object, dict]:
    import asyncio
    import base64

    from crawl4ai import AsyncWebCrawler, BrowserConfig, CacheMode, CrawlerRunConfig

    async def run() -> tuple[str | None, bytes | None, object, dict]:
        browser = BrowserConfig(headless=True, verbose=False)
        config = CrawlerRunConfig(
            cache_mode=CacheMode.BYPASS,
            word_count_threshold=0,
            keep_data_attributes=True,
            excluded_tags=[],
            screenshot=True,
            page_timeout=timeout_ms,
            check_robots_txt=True,
        )
        async with AsyncWebCrawler(config=browser) as crawler:
            result = await crawler.arun(url=url, config=config)
        diagnostics = {
            "success": bool(result.success),
            "statusCode": getattr(result, "status_code", None),
            "error": getattr(result, "error_message", None),
            "robots": "checked",
        }
        html = result.html if result.success else None
        screenshot = base64.b64decode(result.screenshot) if getattr(result, "screenshot", None) else None
        candidates = None
        if getattr(result, "extracted_content", None):
            try:
                candidates = json.loads(result.extracted_content)
            except json.JSONDecodeError:
                candidates = result.extracted_content
        return html, screenshot, candidates, diagnostics

    return asyncio.run(run())


def self_test() -> None:
    html = """
    <div data-target="ticket" hidden>
      <h2>チケット</h2>
      <h3>東京公演</h3>
      <p>9,900円</p>
      <a href="/jp">日本国内受付</a>
      <a href="https://example.com/overseas">海外受付</a>
    </div>
    """
    blocks = blocks_from_html(html, "self-test", "https://www.lovelive-anime.jp/live/")
    match = next(block for block in blocks if block["headingPath"] == ["チケット", "東京公演"])
    assert match["pane"] == "ticket", match
    assert [link["label"] for link in match["links"]] == ["日本国内受付", "海外受付"]
    assert any(line == "9,900円" for line in match["rawLines"])
    print("capture self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser(description=f"Capture an official page.\n\n{ATTRIBUTION}")
    parser.add_argument("--url", help="Page URL. Required unless --self-test.")
    parser.add_argument("--html", type=Path, help="Replay a saved HTML file instead of launching a browser.")
    parser.add_argument("--out", type=Path, help="Snapshot directory, for example snapshots/capture-id.")
    parser.add_argument("--browser", action="store_true", help="Use Crawl4AI's browser. Requires crawl4ai==0.9.4.")
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if not args.url or not args.out:
        parser.error("--url and --out are required")
    capture_id = args.out.name
    diagnostics: dict = {"attribution": ATTRIBUTION}
    response_html = None
    browser_html = None
    screenshot = None
    candidates: object = None
    status, body, error = fetch_http(args.url, args.timeout)
    diagnostics["httpStatus"] = status
    diagnostics["httpError"] = error
    if body is not None and status and status < 400:
        response_html = body
    if args.html:
        browser_html = args.html.read_text(encoding="utf-8")
        diagnostics["browser"] = "saved-html"
        transport = "savedHtml"
    elif args.browser:
        browser_html, screenshot, candidates, browser_diagnostics = capture_browser(args.url, int(args.timeout * 1000))
        diagnostics.update(browser_diagnostics)
        transport = "crawl4ai"
    else:
        transport = "urlSession"
    write_snapshot(args.out, capture_id, args.url, transport, response_html, browser_html, screenshot, candidates, diagnostics)
    print(args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
