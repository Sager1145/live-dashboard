"""httpx-based fetcher: UA, ja Accept-Language, per-host rate limit, retry/backoff.

Never bypasses login/captcha. Records the redirect chain and the response
headers used later for version detection (ETag / Last-Modified /
Content-Length) — see snapshots.Snapshot. No content hashing is used;
content-digest based version detection is a follow-up that needs approval
(explicitly out of scope here).
"""
from __future__ import annotations

import time
from datetime import UTC, datetime

import httpx

from .snapshots import Snapshot

USER_AGENT = (
    "LiveDashboardCollector/0.1 (+https://github.com/Sager1145/live-dashboard; "
    "contact: sagerxjp@gmail.com) research/non-commercial fixture-driven collector"
)

DEFAULT_HEADERS = {
    "User-Agent": USER_AGENT,
    "Accept-Language": "ja,en;q=0.5",
}

HEADER_KEEP = ("etag", "last-modified", "content-length", "content-type")


class RateLimiter:
    """Simple per-host minimum-interval rate limiter."""

    def __init__(self, min_interval_seconds: float = 1.0) -> None:
        self.min_interval = min_interval_seconds
        self._last_request: dict[str, float] = {}

    def wait(self, host: str) -> None:
        last = self._last_request.get(host)
        now = time.monotonic()
        if last is not None:
            elapsed = now - last
            if elapsed < self.min_interval:
                time.sleep(self.min_interval - elapsed)
        self._last_request[host] = time.monotonic()


class Fetcher:
    def __init__(
        self,
        client: httpx.Client | None = None,
        rate_limiter: RateLimiter | None = None,
        max_retries: int = 3,
        backoff_seconds: float = 1.5,
    ) -> None:
        self._client = client or httpx.Client(
            headers=DEFAULT_HEADERS, follow_redirects=True, timeout=20.0
        )
        self._rate_limiter = rate_limiter or RateLimiter()
        self.max_retries = max_retries
        self.backoff_seconds = backoff_seconds

    def close(self) -> None:
        self._client.close()

    def fetch(self, url: str) -> Snapshot:
        host = httpx.URL(url).host
        last_exc: Exception | None = None
        for attempt in range(self.max_retries):
            self._rate_limiter.wait(host)
            try:
                response = self._client.get(url)
            except httpx.HTTPError as exc:  # network error, retry with backoff
                last_exc = exc
                time.sleep(self.backoff_seconds * (attempt + 1))
                continue

            if response.status_code in (401, 403) or "captcha" in response.text[:2000].lower():
                # Do not attempt to bypass login/captcha walls.
                return Snapshot(
                    requested_url=url,
                    final_url=str(response.url),
                    html=response.text,
                    status=response.status_code,
                    fetched_at=_now_iso(),
                    headers=_keep_headers(response.headers),
                )

            if response.status_code >= 500:
                last_exc = httpx.HTTPStatusError(
                    "server error", request=response.request, response=response
                )
                time.sleep(self.backoff_seconds * (attempt + 1))
                continue

            return Snapshot(
                requested_url=url,
                final_url=str(response.url),
                html=response.text,
                status=response.status_code,
                fetched_at=_now_iso(),
                headers=_keep_headers(response.headers),
            )

        raise RuntimeError(f"failed to fetch {url} after {self.max_retries} attempts") from last_exc


def _now_iso() -> str:
    return datetime.now(UTC).isoformat()


def _keep_headers(headers: httpx.Headers) -> dict[str, str]:
    return {k: headers[k] for k in HEADER_KEEP if k in headers}
