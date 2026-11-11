#!/usr/bin/env python3
# Copyright (c) 2026 Jeff DeWall
# SPDX-License-Identifier: MPL-2.0
"""Fail on a pointer to a design document that no longer exists.

glyphwire once kept its design rationale in docs/decisions.md and its
implementation log in docs/roadmap.md (and before that, slice plans).
They grew too big to read and drifted from the code, so they were deleted,
and the rationale now lives next to what it explains: a comment, the
`//!` module doc of the file that owns the behaviour, or for the protocol,
docs/protocol.md. "See decisions.md's X section" kept getting written
after the file was gone, which leaves the reader with no reason at all.

    scripts/check-doc-refs.py   # exit 1, listing each hit, if any remain

Scans every file git tracks, except the ones that name the old documents
on purpose (this script and CONTRIBUTING.md, which says they are gone).
"""

import re
import subprocess
import sys

DEAD = re.compile(r"\b(decisions|roadmap|slice_plan)\.md\b")

# Files that mention the dead names deliberately.
ALLOWED = {"scripts/check-doc-refs.py", "CONTRIBUTING.md"}


def main():
    files = subprocess.run(
        ["git", "ls-files", "-z"], check=True, capture_output=True
    ).stdout.decode().split("\0")
    hits = []
    for path in files:
        if not path or path in ALLOWED:
            continue
        try:
            with open(path, encoding="utf-8") as f:
                for n, line in enumerate(f, 1):
                    if DEAD.search(line):
                        hits.append(f"{path}:{n}: {line.strip()}")
        except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
            continue  # binary files, and paths deleted but not yet staged
    if hits:
        print("check-doc-refs: pointers to deleted design docs; state the "
              "reason inline instead:", file=sys.stderr)
        for h in hits:
            print(f"  {h}", file=sys.stderr)
        sys.exit(1)
    print("check-doc-refs: ok")


main()
