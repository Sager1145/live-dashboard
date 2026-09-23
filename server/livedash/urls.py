"""URL normalization and stable ID helpers.

Stable IDs are derived from source id + path/params only — NEVER from dates,
so that a postponed performance keeps its identity (DESIGN.md 三).
"""
from __future__ import annotations

from urllib.parse import parse_qsl, urlencode, urlparse, urlunparse

_TRACKING_PREFIXES = ("utm_",)
_TRACKING_EXACT = {"fbclid", "gclid", "yclid", "_ga", "igshid", "mc_cid", "mc_eid", "ref", "ref_src"}

# host -> path suffix -> whitelist of query params that carry semantic identity
# and must always be kept even though most query params are stripped.
_SEMANTIC_PARAMS: dict[str, dict[str, set[str]]] = {
    "www.lovelive-anime.jp": {
        "live_detail.php": {"p", "_id"},
    },
    "bushiroad-store.com": {
        "": {"page"},  # list pages: bushiroad-store.com/blogs/live?page=2
    },
}


def _is_tracking_param(key: str) -> bool:
    lowered = key.lower()
    if lowered in _TRACKING_EXACT:
        return True
    return any(lowered.startswith(prefix) for prefix in _TRACKING_PREFIXES)


def normalize_url(url: str) -> str:
    """Strip tracking params and fragments, lowercase host, keep whitelisted params.

    `p` (and the lovehigh branch's `_id`) on live_detail.php is part of the
    performance identity and must NEVER be dropped; `page` on bushiroad-store
    list pages is kept for the same reason.
    """
    parsed = urlparse(url)
    host = parsed.netloc.lower()
    path = parsed.path

    whitelist: set[str] = set()
    host_rules = _SEMANTIC_PARAMS.get(host, {})
    for suffix, params in host_rules.items():
        if suffix == "" or path.endswith(suffix):
            whitelist |= params

    kept_params = []
    for key, value in parse_qsl(parsed.query, keep_blank_values=True):
        if _is_tracking_param(key):
            continue
        if whitelist and key not in whitelist:
            # Only drop non-whitelisted params on hosts/paths that *have* a
            # whitelist; hosts without any rule keep all non-tracking params.
            continue
        kept_params.append((key, value))

    new_query = urlencode(kept_params)
    normalized = urlunparse((parsed.scheme, host, path, parsed.params, new_query, ""))
    return normalized


def stable_id(source_id: str, path_or_params: str) -> str:
    """Build a stable, human-readable, date-free identifier.

    Example: stable_id("lovelive", "15th_lovelivefest") ->
    "lovelive:15th_lovelivefest"
    """
    slug = path_or_params.strip("/")
    slug = slug.replace("?", ":").replace("&", "_").replace("=", "-")
    return f"{source_id}:{slug}" if not slug.startswith(f"{source_id}:") else slug
