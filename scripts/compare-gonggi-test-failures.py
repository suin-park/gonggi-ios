#!/usr/bin/env python3
"""Compare GonggiTests failure sets between base and feature (differential regression).

Input files are newline-separated test identifiers, e.g.:
  GonggiTests.ServiceIATests/testKeychainRoundTrip

Exit codes:
  0 — no new regressions (feature-only failures empty)
  1 — new regressions present
  2 — usage / I/O error
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def load_ids(path: Path) -> set[str]:
    if not path.exists():
        raise FileNotFoundError(path)
    ids: set[str] = set()
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        ids.add(line)
    return ids


def parse_failures_from_xcodebuild_log(log_path: Path) -> set[str]:
    """Extract failed XCTest identifiers from an xcodebuild log."""
    import re

    text = log_path.read_text(encoding="utf-8", errors="replace")
    # Test Case '-[GonggiTests.Foo testBar]' failed
    pat = re.compile(
        r"Test Case '-\[(?P<suite>[A-Za-z0-9_.]+) (?P<name>[A-Za-z0-9_]+)]' failed"
    )
    ids: set[str] = set()
    for m in pat.finditer(text):
        suite = m.group("suite")
        name = m.group("name")
        # Normalize GonggiTests.Foo → GonggiTests.Foo/testName
        ids.add(f"{suite}/{name}")
    return ids


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--base-failures", type=Path, help="Newline-separated failure IDs for base")
    p.add_argument("--head-failures", type=Path, help="Newline-separated failure IDs for head")
    p.add_argument("--base-log", type=Path, help="Optional xcodebuild log for base")
    p.add_argument("--head-log", type=Path, help="Optional xcodebuild log for head")
    p.add_argument("--out-json", type=Path, required=True)
    p.add_argument("--out-summary", type=Path, help="Markdown summary path")
    args = p.parse_args()

    try:
        if args.base_failures:
            base = load_ids(args.base_failures)
        elif args.base_log:
            base = parse_failures_from_xcodebuild_log(args.base_log)
        else:
            print("Need --base-failures or --base-log", file=sys.stderr)
            return 2

        if args.head_failures:
            head = load_ids(args.head_failures)
        elif args.head_log:
            head = parse_failures_from_xcodebuild_log(args.head_log)
        else:
            print("Need --head-failures or --head-log", file=sys.stderr)
            return 2
    except OSError as e:
        print(f"I/O error: {e}", file=sys.stderr)
        return 2

    common = sorted(base & head)
    new_regressions = sorted(head - base)
    fixed = sorted(base - head)

    report = {
        "base_failure_count": len(base),
        "head_failure_count": len(head),
        "common_failures": common,
        "new_regressions": new_regressions,
        "fixed_on_head": fixed,
        "pass": len(new_regressions) == 0,
    }
    args.out_json.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    lines = [
        "## Differential GonggiTests regression",
        "",
        f"- Base failures: **{len(base)}**",
        f"- Head failures: **{len(head)}**",
        f"- Common (baseline): **{len(common)}**",
        f"- New regressions: **{len(new_regressions)}**",
        f"- Fixed on head: **{len(fixed)}**",
        "",
    ]
    if new_regressions:
        lines.append("### ❌ New regressions (must be 0 for release)")
        lines.extend(f"- `{t}`" for t in new_regressions)
        lines.append("")
    else:
        lines.append("### ✅ No new regressions vs base")
        lines.append("")
    if common:
        lines.append("### Baseline failures (present on base and head)")
        lines.extend(f"- `{t}`" for t in common)
        lines.append("")
    if fixed:
        lines.append("### Improved on head (failed on base, pass on head)")
        lines.extend(f"- `{t}`" for t in fixed)
        lines.append("")

    md = "\n".join(lines) + "\n"
    if args.out_summary:
        args.out_summary.write_text(md, encoding="utf-8")
    print(md)

    return 0 if report["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
