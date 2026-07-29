#!/usr/bin/env python3
"""Check local Markdown links without requiring network access."""

from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent
LINK = re.compile(r"(?<!!)\[[^\]]+\]\(([^)]+)\)")
SKIP_PREFIXES = ("http://", "https://", "mailto:", "#")


def main() -> int:
    failures: list[str] = []
    for document in sorted(ROOT.rglob("*.md")):
        if ".git" in document.parts:
            continue
        for line_number, line in enumerate(
            document.read_text(encoding="utf-8").splitlines(), start=1
        ):
            for raw_target in LINK.findall(line):
                target = raw_target.strip().split(maxsplit=1)[0].strip("<>")
                if not target or target.startswith(SKIP_PREFIXES):
                    continue
                path_text = unquote(target.split("#", 1)[0])
                if not path_text:
                    continue
                candidate = (document.parent / path_text).resolve()
                if not candidate.exists():
                    relative = document.relative_to(ROOT)
                    failures.append(f"{relative}:{line_number}: missing {target}")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("Markdown links: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

