#!/usr/bin/env bash
#
# Runs the `glyphwire-remote-test` image (see
# build-remote-test-image.sh) as a disposable "remote box" listening on
# localhost:2222, and prints the `glyphwire --ssh` command to reach it.
#
#   ./scripts/run-remote-test-container.sh
#
set -euo pipefail

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

NAME="glyphwire-remote-test"
PORT="${GLYPHWIRE_REMOTE_TEST_PORT:-2222}"

docker rm -f "$NAME" >/dev/null 2>&1 || true

# If the usual key exists, mount it in as authorized_keys so `ssh` can
# connect without a password -- still fine to skip and use the
# password below instead, which is the path that exercises glyphwire's
# in-window SSH_ASKPASS prompt.
MOUNT_ARGS=()
for key in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
    if [ -f "$key" ]; then
        say "found $key -- mounting as authorized_keys"
        MOUNT_ARGS=(-v "$key:/run/secrets/authorized_keys:ro")
        break
    fi
done

say "starting $NAME on 127.0.0.1:$PORT"
docker run -d --name "$NAME" -p "127.0.0.1:$PORT:22" "${MOUNT_ARGS[@]}" glyphwire-remote-test >/dev/null

cat <<EOF

Remote box is up: glyphwire@localhost:$PORT (password: glyphwire)

The container's host key is new every rebuild, so point ssh at a
throwaway known_hosts rather than polluting your real one:

  glyphwire --ssh glyphwire@localhost -- \\
      -p $PORT -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=accept-new

First connect will either prompt for the password in the glyphwire
window (if no key was mounted above) or log straight in (if one was).

Stop it with: docker rm -f $NAME
EOF
