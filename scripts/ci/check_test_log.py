#!/usr/bin/env python3
"""CI gate for the full GonggiTests run.

Fails (exit 1) when:
  1. a test fails that is not in the known-failure baseline (ci/known_test_failures.txt),
  2. the test process crashed / was restarted (fatal error, unexpected exit, signal),
  3. a test declared in GonggiTests/*.swift never ran (not passed, failed or skipped).
Known failures that now pass are reported (remove them from the baseline) but do not fail.
"""
import argparse
import os
import re
import sys
from pathlib import Path

RESULT = [
    re.compile(r"Test Case '-\[(?:\w+)\.(\w+) (\w+)\]' (passed|failed|skipped)"),
    re.compile(r"Test case '(\w+)\.(\w+)\(\)' (passed|failed|skipped)"),  # parallel-testing format
]
CRASH = re.compile(
    r"Fatal error:|Restarting after unexpected exit|crashed while running|"
    r"terminated due to signal|Test crashed with signal|Early unexpected exit|The test runner exited with"
)
CLASS = re.compile(r"^\s*(?:final\s+|@MainActor\s+|open\s+|public\s+)*class\s+(\w+)\s*:\s*[^{]*XCTestCase", re.M)
FUNC = re.compile(r"^\s*(?:@MainActor\s+)?(?:override\s+)?func\s+(test\w*)\s*\(\s*\)", re.M)


def declared_tests(tests_dir: Path, exclude: set[str]) -> set[str]:
    out = set()
    for f in sorted(tests_dir.rglob("*.swift")):
        src = f.read_text(encoding="utf-8", errors="replace")
        classes = [(m.start(), m.group(1)) for m in CLASS.finditer(src)]
        if not classes:
            continue
        for m in FUNC.finditer(src):
            owner = None
            for pos, name in classes:
                if pos < m.start():
                    owner = name
            if owner and owner not in exclude:
                out.add(f"{owner}/{m.group(1)}")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True)
    ap.add_argument("--known", required=True)
    ap.add_argument("--tests-dir", required=True)
    ap.add_argument("--exclude-class", action="append", default=[])
    a = ap.parse_args()

    log = Path(a.log).read_text(encoding="utf-8", errors="replace")
    known = {l.strip() for l in Path(a.known).read_text().splitlines() if l.strip() and not l.startswith("#")}
    results: dict[str, set[str]] = {}
    for line in log.splitlines():
        for rx in RESULT:
            m = rx.search(line)
            if m:
                results.setdefault(f"{m.group(1)}/{m.group(2)}", set()).add(m.group(3))
    failed = {t for t, s in results.items() if "failed" in s}
    ran = set(results)
    crashes = sorted({l.strip()[:200] for l in log.splitlines() if CRASH.search(l)})
    declared = declared_tests(Path(a.tests_dir), set(a.exclude_class))
    missing = sorted(declared - ran)
    new_failures = sorted(failed - known)
    fixed = sorted((known - failed) & ran)

    lines = [
        "### GonggiTests gate",
        f"- declared tests: {len(declared)}, executed: {len(ran & declared)} (+{len(ran - declared)} not matched to source)",
        f"- failed: {len(failed)} (known baseline {len(known)}), new failures: {len(new_failures)}",
        f"- crash / restart markers: {len(crashes)}",
        f"- declared but not executed: {len(missing)}",
    ]
    for title, items in (("New failures", new_failures), ("Crash markers", crashes),
                         ("Declared but not executed", missing), ("Known failures now passing (update baseline)", fixed)):
        if items:
            lines.append(f"\n**{title}**")
            lines += [f"- `{x}`" for x in items[:200]]
    text = "\n".join(lines)
    print(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(text + "\n")
    return 1 if (new_failures or crashes or missing) else 0


if __name__ == "__main__":
    sys.exit(main())
