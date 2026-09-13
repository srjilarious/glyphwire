#!/usr/bin/env python3
# Copyright (c) 2026 Jeff DeWall
# SPDX-License-Identifier: MPL-2.0
"""Verify glyphwire's three-way licence split holds.

glyphwire is MPL-2.0 (the embeddable plumbing), GPL-3.0-or-later (the
end-user applications) and CC-BY-4.0 (the protocol spec and docs) -- see
LICENSE.md. Code is expected to move between those zones over time, and
two mistakes are easy to make while moving it:

  * `git mv` carries the old SPDX header into the new zone, so the header
    and LICENSE.md disagree about the same file. The header is what a
    downstream vendor actually reads, so it silently wins.
  * A file relicensed to MPL keeps importing a GPL module, which makes the
    MPL library undistributable as MPL.

This script fails on either, plus a few related invariants. Run it before
committing a move:

    zig build check-licenses        # or: scripts/check-licenses.py

Module licences are derived from where each module's root source file
lives, not hardcoded -- so moving `ls/support.zig` into `src/`
automatically reclassifies the `ls_support` module as MPL here, with no
edit to this file.
"""

import os
import re
import sys

HOLDER = "Copyright (c) 2026 Jeff DeWall"

MPL = "MPL-2.0"
GPL = "GPL-3.0-or-later"
CCBY = "CC-BY-4.0"

# Directory -> licence. The single source of truth, mirroring LICENSE.md.
ZONES = {
    MPL: ["src", "host", "host_eng", "server", "client", "agent",
          "notify", "debug", "demo", "table-demo"],
    GPL: ["shell", "gmux", "ls", "view", "read", "zoe", "tests"],
}

# Third-party trees, including ones nested inside our own directories.
# Never headed, never checked.
THIRD_PARTY = ("host_eng/libs/", "libs/", "vendor/", "zig-pkg/",
               ".zig-cache/", "zig-out/", ".provision-dist/", ".git/")

# Build files live with the MPL plumbing.
BUILD_FILES = ["build.zig", "build.zig.zon"]

# Everything under these is CC-BY-4.0.
DOC_DIRS = ["docs"]
DOC_FILES = ["README.md"]

SPDX_RE = re.compile(r"SPDX-License-Identifier:\s*(\S+)")
IMPORT_RE = re.compile(r'@import\("([^"]+)"\)')
# b.addModule("name", .{ .root_source_file = b.path("dir/file.zig") ...
ADDMODULE_RE = re.compile(
    r'addModule\(\s*"([^"]+)"\s*,\s*\.\{.*?b\.path\("([^"]+)"\)', re.S)

errors = []
warnings = []


def err(path, msg):
    errors.append(f"{path}: {msg}")


def is_third_party(path):
    return path.startswith(THIRD_PARTY)


def zone_of(path):
    """The licence a path is expected to carry, or None if unmanaged."""
    if is_third_party(path):
        return None
    top = path.split(os.sep)[0]
    for lic, dirs in ZONES.items():
        if top in dirs:
            return lic
    if path in BUILD_FILES:
        return MPL
    if top in DOC_DIRS or path in DOC_FILES:
        return CCBY
    return None


def walk(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames
                       if not is_third_party(
                           os.path.join(dirpath, d).lstrip("./") + "/")]
        for fn in filenames:
            p = os.path.normpath(os.path.join(dirpath, fn))
            if not is_third_party(p):
                yield p


def read(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def declared_spdx(text):
    m = SPDX_RE.search(text[:600])
    return m.group(1) if m else None


# ── 1. Module licences, derived from build.zig ────────────────────────────

def module_licences():
    """Map each build.zig module name to the licence of its root source."""
    text = read("build.zig")
    out = {}
    for name, src in ADDMODULE_RE.findall(text):
        z = zone_of(os.path.normpath(src))
        if z is not None:
            out[name] = z
    return out


# ── 2. Every managed source file carries the right header ─────────────────

def check_headers(mod_lic):
    checked = 0
    for lic, dirs in ZONES.items():
        for d in dirs:
            if not os.path.isdir(d):
                continue
            for p in walk(d):
                if not p.endswith(".zig"):
                    continue
                checked += 1
                got = declared_spdx(read(p))
                if got is None:
                    err(p, f"no SPDX header (expected {lic})")
                elif got != lic:
                    err(p, f"header says {got}, but {p.split(os.sep)[0]}/ "
                           f"is {lic} — did this file move zones?")

    for p in BUILD_FILES:
        if os.path.exists(p):
            checked += 1
            got = declared_spdx(read(p))
            if got != MPL:
                err(p, f"header says {got}, expected {MPL}")

    for d in DOC_DIRS:
        for p in walk(d):
            if p.endswith(".md"):
                checked += 1
                if declared_spdx(read(p)) != CCBY:
                    err(p, f"docs must be {CCBY}")
    for p in DOC_FILES:
        if os.path.exists(p):
            checked += 1
            if declared_spdx(read(p)) != CCBY:
                err(p, f"expected {CCBY}")
    return checked


# ── 3. No MPL file may depend on a GPL module ─────────────────────────────

def check_import_direction(mod_lic):
    gpl_dirs = set(ZONES[GPL])
    edges = 0
    for d in ZONES[MPL]:
        if not os.path.isdir(d):
            continue
        for p in walk(d):
            if not p.endswith(".zig"):
                continue
            # Only police files that actually claim MPL; a mis-headed file
            # is already reported by check_headers.
            if declared_spdx(read(p)) != MPL:
                continue
            for imp in IMPORT_RE.findall(read(p)):
                edges += 1
                if mod_lic.get(imp) == GPL:
                    err(p, f'imports GPL module "{imp}" — an MPL file may '
                           f"not depend on one (see CONTRIBUTING.md)")
                if imp.endswith(".zig") and (".." + os.sep) in imp:
                    target = os.path.normpath(os.path.join(os.path.dirname(p), imp))
                    if target.split(os.sep)[0] in gpl_dirs:
                        err(p, f'relative-imports GPL source "{imp}"')
    return edges


# ── 4. MPL Exhibit B would break every GPL binary here ────────────────────

def check_exhibit_b():
    needle = "Incompatible With Secondary Licenses"
    for lic, dirs in ZONES.items():
        for d in dirs:
            if not os.path.isdir(d):
                continue
            for p in walk(d):
                if p.endswith((".zig", ".md")) and needle in read(p):
                    err(p, "carries MPL Exhibit B — this would make the GPL "
                           "programs undistributable; never add it")


# ── 5. Licence texts are present ──────────────────────────────────────────

def check_texts():
    for lic in (MPL, GPL, CCBY):
        p = os.path.join("LICENSES", lic + ".txt")
        if not os.path.exists(p):
            err(p, "licence text missing")


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(root)

    if not os.path.exists("build.zig"):
        print("check-licenses: not at the repo root", file=sys.stderr)
        return 2

    mod_lic = module_licences()
    n_files = check_headers(mod_lic)
    n_edges = check_import_direction(mod_lic)
    check_exhibit_b()
    check_texts()

    gpl_mods = sorted(m for m, l in mod_lic.items() if l == GPL)
    print(f"check-licenses: {n_files} files, {n_edges} imports from MPL "
          f"sources, {len(mod_lic)} modules "
          f"({len(gpl_mods)} GPL: {', '.join(gpl_mods) or 'none'})")

    for w in warnings:
        print(f"  warning: {w}")
    if errors:
        print(f"\n{len(errors)} problem(s):\n", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        print("\nSee LICENSE.md for the zone map and CONTRIBUTING.md for "
              "the rules.", file=sys.stderr)
        return 1
    print("check-licenses: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
