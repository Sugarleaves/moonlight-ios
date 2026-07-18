#!/usr/bin/env python3

import re
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Optional, Set


ROOT = Path(__file__).resolve().parents[2]
COMMON = ROOT / "moonlight-common" / "moonlight-common-c"
HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
WARNING = re.compile(r"(?P<path>/[^:\n]+):(?P<line>\d+):\d+: warning:")


def git(repo: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def collect_changed_lines(repo: Path, prefix: str) -> Dict[str, Set[int]]:
    base = git(repo, "merge-base", "origin/master", "HEAD")
    diff = git(repo, "diff", "--unified=0", f"{base}..HEAD", "--", "*.c", "*.h", "*.m")
    changed: Dict[str, Set[int]] = {}
    current_file: Optional[str] = None

    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            current_file = prefix + line[6:]
        elif current_file and (match := HUNK.match(line)):
            start = int(match.group(1))
            count = int(match.group(2) or "1")
            changed.setdefault(current_file, set()).update(range(start, start + count))

    return changed


def repository_relative_path(path: str) -> Optional[str]:
    marker = "/moonlight-ios/moonlight-ios/"
    if marker in path:
        return path.split(marker, 1)[1]
    return None


def main() -> int:
    changed = collect_changed_lines(ROOT, "")
    changed.update(collect_changed_lines(COMMON, "moonlight-common/moonlight-common-c/"))
    new_warnings: List[str] = []

    for log_name in sys.argv[1:]:
        for line in Path(log_name).read_text(errors="replace").splitlines():
            match = WARNING.search(line)
            if not match:
                continue
            relative = repository_relative_path(match.group("path"))
            if relative and int(match.group("line")) in changed.get(relative, set()):
                new_warnings.append(line)

    if new_warnings:
        print("Warnings found on lines changed by Desktop Touch Mode:", file=sys.stderr)
        print("\n".join(new_warnings), file=sys.stderr)
        return 1

    print("No compiler or analyzer warnings on changed Desktop Touch lines.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
