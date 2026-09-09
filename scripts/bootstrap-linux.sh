#!/usr/bin/env bash
#
# Repeatable Linux build of glyphwire with the pinned Zig toolchain.
#
# This does NOT install Zig. glyphwire's dev branch tracks an unreleased
# Zig (see REQUIRED_ZIG below); install exactly that version yourself, put
# it on PATH, then run this script. It verifies the toolchain, checks the
# few system prerequisites, primes the package cache and builds the
# shipped programs.
#
#   ./scripts/bootstrap-linux.sh                     # zig build package -Doptimize=ReleaseSafe
#   ./scripts/bootstrap-linux.sh tests               # forward any args to `zig build`
#
set -euo pipefail

# Keep this in step with build.zig.zon's `minimum_zig_version`.
REQUIRED_ZIG="0.17.0-dev.1857+3c46da14d"

# Where to get it: this exact dev build is pruned from ziglang.org, but the
# mach project keeps it (nomination 2026.7.30-mach) on a permanent mirror.
ZIG_TARBALL_URL="https://pkg.hexops.org/zig/zig-x86_64-linux-${REQUIRED_ZIG}.tar.xz"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- platform ---------------------------------------------------------------
[ "$(uname -s)" = "Linux" ]   || die "this script targets Linux (found $(uname -s))"
[ "$(uname -m)" = "x86_64" ]  || die "this script targets x86_64 (found $(uname -m))"

# --- zig -----------------------------------------------------------------
command -v zig >/dev/null 2>&1 || die "zig not found on PATH.
  Install Zig ${REQUIRED_ZIG} and re-run. Direct download:
    curl -fL '${ZIG_TARBALL_URL}' | tar -xJ
  then add the extracted directory to PATH."

have_zig="$(zig version)"
if [ "$have_zig" != "$REQUIRED_ZIG" ] && [ "${BOOTSTRAP_SKIP_ZIG_CHECK:-}" != "1" ]; then
  die "wrong Zig version.
  need:  ${REQUIRED_ZIG}
  found: ${have_zig}  ($(command -v zig))
  Download the pinned build:
    curl -fL '${ZIG_TARBALL_URL}' | tar -xJ
  and put its directory ahead of the current zig on PATH.
  (Set BOOTSTRAP_SKIP_ZIG_CHECK=1 to bypass this at your own risk.)"
fi

# --- system prerequisites -------------------------------------------------
# The host backend vendors its own X11/Wayland headers and dlopens the
# client libs at runtime, so no -dev packages are needed to build. Zig
# fetches the git+https dependencies itself, but it still wants a system
# CA bundle, and `git` for the git protocol.
missing=()
command -v git >/dev/null 2>&1 || missing+=("git")
# Debian/Ubuntu ships the CA bundle here; other distros vary.
[ -e /etc/ssl/certs/ca-certificates.crt ] || [ -e /etc/pki/tls/certs/ca-bundle.crt ] || missing+=("ca-certificates")

if [ "${#missing[@]}" -ne 0 ]; then
  if command -v apt-get >/dev/null 2>&1; then
    say "installing prerequisites: ${missing[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y -qq --no-install-recommends "${missing[@]}"
  else
    die "missing prerequisites: ${missing[*]} (install them with your package manager and re-run)"
  fi
fi

# --- package cache ------------------------------------------------------
# Pin the global cache to a known path and pre-create its tmp/ subdir.
# Zig 0.16 could not unpack a .zip dependency (SDL pulls libusb as one)
# into a pristine cache because its zip path did not create tmp/ first;
# 0.17 fixes that, but pre-creating it is free and keeps this script
# correct on a cache-restore CI or an older toolchain.
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$HOME/.cache/zig}"
mkdir -p "$ZIG_GLOBAL_CACHE_DIR/tmp"

# --- build ------------------------------------------------------------
cd "$(dirname "$0")/.."
say "zig version: $(zig version)"

if [ "$#" -eq 0 ]; then
  set -- package -Doptimize=ReleaseSafe
fi

say "zig build $*"
zig build "$@"

if [ "$1" = "package" ]; then
  say "built into ./zig-out"
  ls -1 zig-out/bin 2>/dev/null || true
fi
