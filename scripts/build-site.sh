#!/usr/bin/env bash
#
# Assembles the GitHub Pages site into _site/ (or the directory given).
#
# site/ holds the hand-written pages; the screenshots and logo are not
# copied into it but taken from docs/images/ and assets/ here, so the
# README and the site always show the same images and
# scripts/regen-readme-assets.sh refreshes both at once.
#
# .github/workflows/pages.yml runs this and publishes the result. To
# preview locally:
#
#   scripts/build-site.sh && python3 -m http.server -d _site 8000
#
# Usage:  scripts/build-site.sh [out_dir]

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

out_dir="${1:-_site}"

rm -rf "$out_dir"
mkdir -p "$out_dir/images"

cp -r site/. "$out_dir/"
cp docs/images/*.png "$out_dir/images/"
cp assets/glyphwire_icon.svg assets/glyphwire_icon.png "$out_dir/images/"

# GitHub Pages runs Jekyll over a plain upload unless told not to, which
# would skip any path starting with an underscore.
touch "$out_dir/.nojekyll"

echo "site assembled in $out_dir/"
