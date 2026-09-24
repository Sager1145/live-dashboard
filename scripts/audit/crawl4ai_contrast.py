#!/usr/bin/env python3
"""Optional development-machine contrast crawler.

Crawl4AI is not an iOS dependency. The app keeps URLSession and SwiftSoup.
This script only runs when someone installs crawl4ai locally to save a page
for a fixture. It does not merge official facts by itself.
"""

import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: crawl4ai_contrast.py URL", file=sys.stderr)
        return 2
    try:
        import crawl4ai  # noqa: F401
    except ImportError:
        print("crawl4ai is not installed; the iOS app does not need it", file=sys.stderr)
        return 2
    print("crawl4ai is present. Fetch the URL in a local venv and save the HTML as a fixture.")
    print(sys.argv[1])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
