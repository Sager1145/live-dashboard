"""Adapter protocol and shared HTML/text extraction helpers.

Extraction order (DESIGN.md 二 1):
  identify source/template -> isolate main content region ->
  drop nav/footer/other-recommendations -> split into sections by heading ->
  extract dates/amounts/links/images within a section -> attribute to a
  performance/scope -> validate.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Protocol

from selectolax.parser import HTMLParser, Node

from ..models import Issue
from ..snapshots import Snapshot

JST = timezone(timedelta(hours=9))

# Tags/classes that are never part of "main content" for any of our sources.
NAV_JUNK_SELECTORS = [
    "nav",
    "header",
    "footer",
    "script",
    "style",
    "noscript",
    ".p-header",
    ".p-footer",
    ".l-header",
    ".l-nav",
    ".l-footer",
    ".breadcrumb",
    ".p-breadcrumb",
    ".article__aside",
    ".article__navigation",
    "#shopify-section-announcement-bar",
    ".dynamic-announcement-bar",
    "#shopify-section-header",
    "#shopify-section-footer",
]


@dataclass
class Candidate:
    """A raw extracted record before pydantic validation/publish.

    `kind` matches a LiveEventBundle list name, e.g. "event", "performance",
    "ticketTier", "ticketRound", "goodsCampaign", "mediaAsset", "notice",
    "aliasRelation".
    """

    kind: str
    data: dict[str, Any]
    key: str  # a locally-unique key used to link evidence to this candidate


@dataclass
class EvidenceCandidate:
    candidate_key: str
    field: str
    source_url: str
    quote: str
    source_published_at: str | None = None


@dataclass
class ParseResult:
    candidates: list[Candidate] = field(default_factory=list)
    evidence: list[EvidenceCandidate] = field(default_factory=list)
    issues: list[Issue] = field(default_factory=list)


class Adapter(Protocol):
    name: str
    version: str

    def matches(self, url: str) -> bool: ...

    def parse(self, snapshot: Snapshot) -> ParseResult: ...


def strip_junk(root: Node) -> None:
    """Remove nav/footer/script/other-recommendation nodes in place."""
    for selector in NAV_JUNK_SELECTORS:
        for node in root.css(selector):
            node.decompose()


def isolate_main_content(html: str, selector: str) -> tuple[HTMLParser, Node | None]:
    """Parse HTML and return (tree, main_node) with junk removed from main_node.

    The main_node is a *clone-free* live node from the same tree; junk is
    stripped only within it so unrelated parts of the tree are untouched.
    """
    tree = HTMLParser(html)
    main = tree.css_first(selector)
    if main is not None:
        strip_junk(main)
    return tree, main


# ---------------------------------------------------------------------------
# Date / amount extraction
# ---------------------------------------------------------------------------

_WEEKDAY = r"(?:月|火|水|木|金|土|日)"
_DATE_FULL_RE = re.compile(
    rf"(?P<year>\d{{4}})年(?P<month>\d{{1,2}})月(?P<day>\d{{1,2}})日(?:\({_WEEKDAY}\))?"
)
_TIME_RE = re.compile(r"(?P<h>\d{1,2}):(?P<m>\d{2})")
_YEN_RE = re.compile(r"(?:¥\s?(?P<amount1>[\d,]+)|(?P<amount2>[\d,]+)\s?円)")


@dataclass
class ExtractedDate:
    raw: str
    year: int
    month: int
    day: int


def extract_jp_dates(text: str) -> list[ExtractedDate]:
    """Find `2026年3月14日(土)`-style dates. Does not resolve short forms like
    `3/14(土)` or `～` ranges to a year; callers needing those should combine
    with an already-known year from the same section and emit an Issue
    instead of guessing when no year is available."""
    out = []
    for m in _DATE_FULL_RE.finditer(text):
        out.append(
            ExtractedDate(
                raw=m.group(0),
                year=int(m.group("year")),
                month=int(m.group("month")),
                day=int(m.group("day")),
            )
        )
    return out


def extract_time(text: str) -> tuple[int, int] | None:
    m = _TIME_RE.search(text)
    if not m:
        return None
    return int(m.group("h")), int(m.group("m"))


def extract_yen_amounts(text: str) -> list[int]:
    out = []
    for m in _YEN_RE.finditer(text):
        raw = m.group("amount1") or m.group("amount2")
        out.append(int(raw.replace(",", "")))
    return out


def to_iso_datetime(year: int, month: int, day: int, hour: int | None, minute: int | None) -> str | None:
    try:
        if hour is None or minute is None:
            return None
        dt = datetime(year, month, day, hour, minute, tzinfo=JST)
        return dt.isoformat()
    except ValueError:
        return None


def to_iso_date(year: int, month: int, day: int) -> str | None:
    try:
        datetime(year, month, day)
    except ValueError:
        return None
    return f"{year:04d}-{month:02d}-{day:02d}"


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


# ---------------------------------------------------------------------------
# Image extraction
# ---------------------------------------------------------------------------


@dataclass
class ExtractedImage:
    src: str
    srcset_candidates: list[str]
    lazy_src: str | None
    enclosing_link: str | None
    nearby_text: str


def extract_images(container: Node) -> list[ExtractedImage]:
    out = []
    for img in container.css("img"):
        src = img.attributes.get("src") or ""
        lazy = (
            img.attributes.get("data-src")
            or img.attributes.get("data-lazy")
            or img.attributes.get("data-lazy-src")
        )
        srcset = img.attributes.get("srcset") or img.attributes.get("data-srcset") or ""
        candidates = [c.strip().split(" ")[0] for c in srcset.split(",") if c.strip()]
        if not src and not lazy:
            continue
        link = None
        parent = img.parent
        hops = 0
        while parent is not None and hops < 4:
            if parent.tag == "a" and parent.attributes.get("href"):
                link = parent.attributes.get("href")
                break
            parent = parent.parent
            hops += 1
        nearby = _nearby_heading_text(img)
        out.append(
            ExtractedImage(
                src=src or lazy or "",
                srcset_candidates=candidates,
                lazy_src=lazy,
                enclosing_link=link,
                nearby_text=nearby,
            )
        )
    return out


def _nearby_heading_text(node: Node) -> str:
    """Walk backwards through preceding siblings/ancestors for the closest
    heading or caption-like text to help classify a MediaAsset.kind."""
    current = node
    hops = 0
    while current is not None and hops < 8:
        sib = current.prev
        while sib is not None:
            if sib.tag in ("h1", "h2", "h3", "h4", "h5", "h6"):
                return sib.text(strip=True)
            if sib.tag in ("p",) and sib.text(strip=True):
                return sib.text(strip=True)[:80]
            sib = sib.prev
        current = current.parent
        hops += 1
    return ""


def section_text(container: Node) -> str:
    return container.text(separator="\n", strip=True)


HEADING_TAGS = {"h1", "h2", "h3", "h4", "h5", "h6"}


@dataclass
class FlatSection:
    """One heading and the sibling nodes up to (but excluding) the next
    heading of equal-or-shallower level. Used for BanG Dream! detail pages
    and other templates where sections are a flat run of siblings rather
    than nested containers."""

    tag: str
    level: int
    heading_id: str
    title: str
    nodes: list[Node]

    def text(self) -> str:
        return "\n".join(n.text(separator="\n", strip=True) for n in self.nodes)


def resolve_canonical_url(tree: HTMLParser, fallback: str) -> str:
    """Prefer <link rel=canonical> / og:url over the (possibly fixture://)
    requested/final URL so stable IDs derived from real fixture HTML match
    the real site structure."""
    canonical = tree.css_first('link[rel="canonical"]')
    if canonical is not None and canonical.attributes.get("href"):
        return canonical.attributes["href"]
    og = tree.css_first('meta[property="og:url"]')
    if og is not None and og.attributes.get("content"):
        return og.attributes["content"]
    return fallback


def split_flat_sections(container: Node, heading_tags: set[str] | None = None) -> list[FlatSection]:
    """Split a flat run of sibling nodes into sections keyed by heading."""
    heading_tags = heading_tags or HEADING_TAGS
    sections: list[FlatSection] = []
    current: FlatSection | None = None
    for child in container.iter():
        if child.tag in heading_tags:
            level = int(child.tag[1])
            current = FlatSection(
                tag=child.tag,
                level=level,
                heading_id=child.attributes.get("id") or "",
                title=child.text(strip=True),
                nodes=[],
            )
            sections.append(current)
        elif current is not None:
            current.nodes.append(child)
    return sections
