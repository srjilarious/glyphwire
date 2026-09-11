#!/bin/sh
# Container entrypoint: install whatever authorized_keys
# run-remote-test-container.sh mounted in (if any), then run sshd in the
# foreground. A missing mount just leaves password auth as the only way
# in -- exactly what you want for trying the SSH_ASKPASS prompt flow.
set -e

install -d -m 700 -o glyphwire -g glyphwire /home/glyphwire/.ssh
: > /home/glyphwire/.ssh/authorized_keys
if [ -f /run/secrets/authorized_keys ]; then
    cat /run/secrets/authorized_keys >> /home/glyphwire/.ssh/authorized_keys
fi
chown glyphwire:glyphwire /home/glyphwire/.ssh/authorized_keys
chmod 600 /home/glyphwire/.ssh/authorized_keys

exec /usr/sbin/sshd -D -e
