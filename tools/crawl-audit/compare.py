#!/usr/bin/env python3
"""Compare iPhone source blocks with a Crawl4AI or saved-HTML snapshot.

A missing field is classified as fetch, DOM, or parser. Extractor JSON is never the answer.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ATTRIBUTION = (
    "This product includes software developed by UncleCode "
    "(https://x.com/unclecode) as part of the Crawl4AI project "
    "(https://github.com/unclecode/crawl4ai)."
)


def load_blocks(path: Path) -> list[dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(data, dict) and "blocks" in data:
        data = data["blocks"]
    return data


def key(block: dict) -> tuple:
    return (block.get("pane"), tuple(block.get("headingPath") or []))


def classify(snapshot: Path, iphone: list[dict], crawl: list[dict]) -> list[dict]:
    response = snapshot / "response.html"
    browser = snapshot / "browser-dom.html"
    response_text = response.read_text(encoding="utf-8") if response.exists() else ""
    browser_text = browser.read_text(encoding="utf-8") if browser.exists() else ""
    iphone_keys = {key(block) for block in iphone}
    reports = []
    for block in crawl:
        identity = key(block)
        if identity in iphone_keys:
            continue
        heading = " ".join(block.get("headingPath") or [])
        in_response = bool(heading) and heading in response_text
        in_browser = bool(heading) and heading in browser_text
        if in_browser and not in_response:
            kind = "dom"
            detail = "浏览器 DOM 里有这个标题，独立 HTTP 响应里没有。先看页签或脚本，不改语义规则。"
        elif in_response and not in_browser:
            kind = "fetch"
            detail = "HTTP 响应里有这个标题，浏览器采集里没有。先看过滤或采集失败。"
        elif in_response or in_browser:
            kind = "parser"
            detail = "原文里有这个标题，iPhone 区块里没有。先看 SwiftSoup 区块切分。"
        else:
            kind = "absent"
            detail = "两份采集正文都没有这个标题。"
        reports.append({"kind": kind, "headingPath": block.get("headingPath"), "pane": block.get("pane"), "detail": detail})
    return reports


def self_test() -> None:
    crawl = [
        {"pane": "ticket", "headingPath": ["チケット", "東京公演"], "rawLines": ["9,900円"]},
        {"pane": "ticket", "headingPath": ["配信"], "rawLines": []},
    ]
    iphone = [{"pane": "ticket", "headingPath": ["チケット", "東京公演"], "rawLines": ["9,900円"]}]
    root = Path("/tmp/live-dashboard-compare-self-test")
    root.mkdir(parents=True, exist_ok=True)
    (root / "response.html").write_text("<h2>チケット</h2><h3>東京公演</h3>", encoding="utf-8")
    (root / "browser-dom.html").write_text("<h2>チケット</h2><h3>東京公演</h3><h2>配信</h2>", encoding="utf-8")
    found = classify(root, iphone, crawl)
    assert found == [
        {
            "kind": "dom",
            "headingPath": ["配信"],
            "pane": "ticket",
            "detail": "浏览器 DOM 里有这个标题，独立 HTTP 响应里没有。先看页签或脚本，不改语义规则。",
        }
    ], found
    print("compare self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser(description=f"Compare snapshot blocks.\n\n{ATTRIBUTION}")
    parser.add_argument("--snapshot", type=Path, help="Directory containing blocks.json and the HTML evidence.")
    parser.add_argument("--iphone-blocks", type=Path, help="Source blocks JSON written from the iPhone parser.")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if not args.snapshot or not args.iphone_blocks:
        parser.error("--snapshot and --iphone-blocks are required")
    crawl = load_blocks(args.snapshot / "blocks.json")
    iphone = load_blocks(args.iphone_blocks)
    report = {
        "attribution": ATTRIBUTION,
        "missingFromIPhone": classify(args.snapshot, iphone, crawl),
        "note": "extraction-candidates.json is not treated as the correct parse.",
    }
    json.dump(report, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
