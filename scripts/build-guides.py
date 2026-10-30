#!/usr/bin/env python3
# Copyright (c) 2026 Jeff DeWall
# SPDX-License-Identifier: MPL-2.0
"""Render the app guides in docs/guide/ into HTML pages for the site.

The guides are written as Markdown so they read the same on GitHub, in
gwmd and on the website; this turns each one into <out>/guide/<name>.html
inside site/guide.template.html's frame (the site's header, a sidebar of every
guide, the footer). scripts/build-site.sh calls it.

Links are rewritten so one source works in all three places:

  * `zoe.md#keys`, another guide  -> `zoe.html#keys`
  * `../images/x.png`             -> kept: guide/ sits beside images/
                                     on the site as docs/guide/ does
                                     beside docs/images/ in the repo
  * any other relative path       -> its file on GitHub (main), since
                                     only the guides are published

Needs python-markdown (`apt install python3-markdown`, or pip).

Usage:  scripts/build-guides.py <out_dir>
"""

import html
import os
import posixpath
import re
import sys

import markdown

REPO_URL = "https://github.com/srjilarious/glyphwire"

# The sidebar's order; also the set of pages built. A guide missing from
# this list is an error rather than a page nobody can reach.
PAGES = [
    ("index", "Overview"),
    ("glyphwire", "The window"),
    ("gw-shell", "gw-shell"),
    ("zoe", "zoe"),
    ("gmux", "gmux"),
    ("salacommander", "salacommander"),
    ("gwmd", "gwmd"),
    ("gw-read", "gw-read"),
    ("tools", "Small tools"),
]

GUIDE_DIR = "docs/guide"


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def rewrite_href(href):
    """One link target, as the site needs it (see the module doc)."""
    if re.match(r"^[a-z][a-z0-9+.-]*:", href) or href.startswith(("#", "/")):
        return href
    path, sep, frag = href.partition("#")
    if "/" not in path and path.endswith(".md"):
        return path[:-3] + ".html" + sep + frag
    if path.startswith("../images/"):
        return href
    target = posixpath.normpath(posixpath.join(GUIDE_DIR, path))
    if target.startswith(".."):
        return href
    return f"{REPO_URL}/blob/main/{target}{sep}{frag}"


def rewrite_links(body):
    return re.sub(
        r'(<(?:a|img)\b[^>]*?\b(?:href|src)=")([^"]*)(")',
        lambda m: m.group(1) + rewrite_href(html.unescape(m.group(2))) + m.group(3),
        body,
    )


def render(name, nav_html, frame):
    src = read(os.path.join(GUIDE_DIR, name + ".md"))
    m = re.search(r"^# (.+)$", src, re.M)
    if not m:
        sys.exit(f"build-guides: {name}.md has no `# ` title")
    title = m.group(1).strip()

    md = markdown.Markdown(
        extensions=["tables", "fenced_code", "sane_lists", "toc"],
        extension_configs={"toc": {"permalink": "#", "toc_depth": "2-3"}},
    )
    body = rewrite_links(md.convert(src))

    return (frame
            .replace("{{title}}", html.escape(title))
            .replace("{{nav}}", nav_html.replace(f'href="{name}.html"',
                                                 f'href="{name}.html" aria-current="page"'))
            .replace("{{toc}}", md.toc)
            .replace("{{content}}", body))


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: build-guides.py <out_dir>")
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = os.path.abspath(sys.argv[1])
    os.chdir(root)

    listed = {name for name, _ in PAGES}
    on_disk = {f[:-3] for f in os.listdir(GUIDE_DIR) if f.endswith(".md")}
    if listed != on_disk:
        sys.exit("build-guides: PAGES and docs/guide/ disagree: "
                 f"unlisted {sorted(on_disk - listed)}, "
                 f"missing {sorted(listed - on_disk)}")

    frame = read("site/guide.template.html")
    nav_html = "\n".join(f'<a href="{name}.html">{html.escape(label)}</a>'
                         for name, label in PAGES)

    os.makedirs(os.path.join(out_dir, "guide"), exist_ok=True)
    for name, _ in PAGES:
        with open(os.path.join(out_dir, "guide", name + ".html"), "w",
                  encoding="utf-8") as f:
            f.write(render(name, nav_html, frame))
    print(f"build-guides: {len(PAGES)} pages in {out_dir}/guide/")


if __name__ == "__main__":
    main()
