#!/usr/bin/env bash
#
# Builds the current tree's glyphwire remote-side programs and packages
# them into the `glyphwire-remote-test` Docker image -- a disposable
# "remote box" with sshd for trying `glyphwire --ssh <dest>` against
# without a real second machine. See docker/remote-test/README.md.
#
#   ./scripts/build-remote-test-image.sh
#
# Then: ./scripts/run-remote-test-container.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

DIST_DIR="docker/remote-test/dist"

say "zig build install-local -p $DIST_DIR"
rm -rf "$DIST_DIR"
zig build install-local -p "$DIST_DIR"

say "docker build -t glyphwire-remote-test docker/remote-test"
docker build -t glyphwire-remote-test docker/remote-test

say "built. Next: ./scripts/run-remote-test-container.sh"
