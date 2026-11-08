"""Checks the App Store listing texts in appstore/ (English) and appstore/<lang>/ against App Store limits.

Limits: subtitle 30, keywords 100, promotional text 170, description 4000 characters. Keywords are
comma-separated without spaces after commas, must not repeat words of the app name and must not contain
other brands (no "Immich" in subtitle or keywords; the description may name it for compatibility).
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "appstore"
LANGS = ["en", "de", "fr", "it", "es", "nl", "pt-PT", "pt-BR", "sv", "da", "nb", "fi", "ja", "pl",
         "zh-Hans", "zh-Hant", "ko", "uk", "cs", "tr"]  # fmt: skip
LIMITS = {"subtitle": 30, "keywords": 100, "promotional-text": 170, "description": 4000}
NAME_WORDS = {"photo", "mirror", "sync"}


def main() -> None:
    errors, rows = [], []
    for lang in LANGS:
        folder = ROOT if lang == "en" else ROOT / lang
        sizes = []
        for field, limit in LIMITS.items():
            path = folder / f"{field}.txt"
            if not path.exists():
                errors.append(f"{lang}: {field}.txt missing")
                continue
            text = path.read_text().strip()
            sizes.append(f"{len(text):>4}/{limit}")
            if len(text) > limit:
                errors.append(f"{lang}: {field} is {len(text)} characters (limit {limit})")
            if field in ("subtitle", "keywords") and "immich" in text.lower():
                errors.append(f"{lang}: {field} must not contain the trademark Immich")
            if field == "keywords":
                if re.search(r",\s", text):
                    errors.append(f"{lang}: keywords have spaces after commas")
                words = {w for k in text.lower().split(",") for w in k.split()}
                if repeated := words & NAME_WORDS:
                    errors.append(f"{lang}: keywords repeat app name words {sorted(repeated)}")
        rows.append(f"{lang:<8} " + "  ".join(sizes))
    print("lang     subtitle  keywords  promo     description")
    print("\n".join(rows))
    if errors:
        sys.exit("\n".join(errors))
    print("All listings within App Store limits.")


if __name__ == "__main__":
    main()
