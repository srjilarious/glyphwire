#!/usr/bin/env bash
# One-off manual check: does `ssh ... -- gw-agent --stdio` actually hand
# back a `hello` mux frame, and does it spawn gw-shell on the far side?
# Not part of the build/run flow -- just used once during development to
# verify the container end to end without the full glyphwire GUI.
set -euo pipefail
timeout 3 ssh -p 2222 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=accept-new \
    -o BatchMode=yes glyphwire@localhost -- gw-agent --stdio < /dev/null | xxd | head -5
