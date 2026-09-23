"""Snapshot storage: raw HTML + fetch metadata.

Reading fixtures from tests/fixtures/snapshots works through the same
Snapshot/SnapshotStore interface used for live-fetched pages.
"""
from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Snapshot:
    """A single fetched (or fixture) HTML page plus its metadata."""

    requested_url: str
    final_url: str
    html: str
    status: int = 200
    fetched_at: str = ""
    headers: dict[str, str] = field(default_factory=dict)
    source_id: str | None = None

    @property
    def etag(self) -> str | None:
        return self.headers.get("etag")

    @property
    def last_modified(self) -> str | None:
        return self.headers.get("last-modified")

    @property
    def content_length(self) -> str | None:
        return self.headers.get("content-length") or str(len(self.html.encode("utf-8")))


class SnapshotStore:
    """Saves/loads raw HTML + metadata under a directory.

    Layout: <root>/<name>.html plus <root>/<name>.meta.json
    Fixtures under tests/fixtures/snapshots only have the .html file (no
    metadata sidecar); load_fixture() synthesizes minimal metadata for them.
    """

    def __init__(self, root: Path | str) -> None:
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)

    def save(self, name: str, snapshot: Snapshot) -> Path:
        html_path = self.root / f"{name}.html"
        meta_path = self.root / f"{name}.meta.json"
        html_path.write_text(snapshot.html, encoding="utf-8")
        meta_path.write_text(
            json.dumps(
                {
                    "requestedUrl": snapshot.requested_url,
                    "finalUrl": snapshot.final_url,
                    "status": snapshot.status,
                    "fetchedAt": snapshot.fetched_at,
                    "headers": snapshot.headers,
                    "sourceId": snapshot.source_id,
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )
        return html_path

    def load(self, name: str) -> Snapshot:
        html_path = self.root / f"{name}.html"
        meta_path = self.root / f"{name}.meta.json"
        html = html_path.read_text(encoding="utf-8", errors="replace")
        if meta_path.exists():
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            return Snapshot(
                requested_url=meta.get("requestedUrl", ""),
                final_url=meta.get("finalUrl", ""),
                html=html,
                status=meta.get("status", 200),
                fetched_at=meta.get("fetchedAt", ""),
                headers=meta.get("headers", {}),
                source_id=meta.get("sourceId"),
            )
        return self.load_fixture(name, html_path)

    def load_by_path(self, path: Path | str) -> Snapshot:
        """Load a fixture HTML file directly by path (used by the CLI/tests)."""
        path = Path(path)
        html = path.read_text(encoding="utf-8", errors="replace")
        return self.load_fixture(path.stem, path, html=html)

    @staticmethod
    def load_fixture(name: str, html_path: Path, html: str | None = None) -> Snapshot:
        if html is None:
            html = html_path.read_text(encoding="utf-8", errors="replace")
        return Snapshot(
            requested_url=f"fixture://{name}",
            final_url=f"fixture://{name}",
            html=html,
            status=200,
            fetched_at=time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(0)),
            headers={},
            source_id=None,
        )
