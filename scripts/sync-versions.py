#!/usr/bin/env python3
# Copyright (c) 2026 Jeff DeWall
# SPDX-License-Identifier: MPL-2.0
"""Copy glyphwire's version numbers into the docs that quote them.

The numbers live in exactly one place each:

  * every program's version: `program_versions` at the top of build.zig
  * the suite (release) version: `.version` in build.zig.zon
  * the protocol version: `protocol_version` in src/protocol.zig

The README (badges, the protocol paragraph, the Applications table, the
`--version` example), site/index.html and docs/protocol.md's header all
repeat them, and hand-copied they drifted: the README once listed zoe
0.19.0 four releases after 0.23.0. This script rewrites those spots from
the sources, so bumping a version is an edit to the source plus one run:

    scripts/sync-versions.py           # rewrite the docs in place
    scripts/sync-versions.py --check   # exit 1 if any doc is stale (CI)

Every pattern below must match at least once. A reworded README that no
longer has the spot fails loudly here rather than silently going stale,
and so does an Applications row naming a program build.zig doesn't know.
"""

import os
import re
import sys

errors = []


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def program_versions():
    src = read("build.zig")
    m = re.search(r"const program_versions = .*?\n\};", src, re.S)
    if not m:
        sys.exit("sync-versions: no program_versions table in build.zig")
    rows = re.findall(r'\.name = "([^"]+)", \.version = "([^"]+)"', m.group(0))
    if not rows:
        sys.exit("sync-versions: program_versions has no rows")
    return dict(rows)


def one(path, pattern):
    m = re.search(pattern, read(path))
    if not m:
        sys.exit(f"sync-versions: no version found in {path}")
    return m.group(1)


def substitute(text, path, pattern, repl):
    """`re.subn` that records an error when `pattern` no longer matches."""
    new, n = re.subn(pattern, repl, text)
    if n == 0:
        errors.append(f"{path}: pattern {pattern!r} matched nothing")
    return new


def sync_readme(text, suite, protocol, programs):
    p = "README.md"
    text = substitute(text, p, r"(badge/Version-)[0-9.]+(-)", rf"\g<1>{suite}\g<2>")
    text = substitute(text, p, r"(badge/Protocol-)[0-9.]+(-)", rf"\g<1>{protocol}\g<2>")
    text = substitute(text, p, r"(protocol is at \*\*version )[0-9.]+(\*\*)",
                      rf"\g<1>{protocol}\g<2>")

    # The `--version` example: `zoe\n0.24.0 (glyphwire 0.29.0, 1b122a9)`.
    text = substitute(text, p, r"(`zoe\s+)[0-9.]+( \(glyphwire )[0-9.]+(,)",
                      rf"\g<1>{programs['zoe']}\g<2>{suite}\g<3>")

    # Applications table rows: | **`zoe`** | 0.24.0 | ... |
    def row(m):
        name = m.group(2)
        if name not in programs:
            errors.append(f"{p}: Applications row `{name}` is not in "
                          "build.zig's program_versions")
            return m.group(0)
        return f"{m.group(1)}{programs[name]}{m.group(3)}"

    return substitute(text, p, r"(\| \*\*`([^`]+)`\*\* \| )[0-9.]+( \|)", row)


def sync_site(text, protocol):
    return substitute(text, "site/index.html", r"(Protocol version )[0-9.]+(,)",
                      rf"\g<1>{protocol}\g<2>")


def sync_spec(text, protocol):
    return substitute(text, "docs/protocol.md", r"(\*\*Version )[0-9.]+( )",
                      rf"\g<1>{protocol}\g<2>")


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(root)
    check = "--check" in sys.argv[1:]

    programs = program_versions()
    suite = one("build.zig.zon", r'\n    \.version = "([^"]+)"')
    protocol = one("src/protocol.zig", r'pub const protocol_version = "([^"]+)"')

    targets = {
        "README.md": lambda t: sync_readme(t, suite, protocol, programs),
        "site/index.html": lambda t: sync_site(t, protocol),
        "docs/protocol.md": lambda t: sync_spec(t, protocol),
    }

    stale = []
    updated = {}
    for path, sync in targets.items():
        old = read(path)
        new = sync(old)
        if new != old:
            stale.append(path)
            updated[path] = new

    if errors:
        for e in errors:
            print(f"sync-versions: {e}", file=sys.stderr)
        return 2

    if check:
        if stale:
            print("sync-versions: stale version numbers in "
                  f"{', '.join(stale)}; run scripts/sync-versions.py",
                  file=sys.stderr)
            return 1
        print("sync-versions: ok")
        return 0

    for path, new in updated.items():
        with open(path, "w", encoding="utf-8") as f:
            f.write(new)
    print(f"sync-versions: updated {', '.join(stale)}" if stale
          else "sync-versions: already up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
