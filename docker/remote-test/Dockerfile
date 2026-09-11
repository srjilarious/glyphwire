# A disposable "remote box" for exercising `glyphwire --ssh <dest>`
# locally: sshd plus the remote-side glyphwire programs, nothing else.
# Built and run via scripts/build-remote-test-image.sh and
# scripts/run-remote-test-container.sh -- see docker/remote-test/README.md.
#
# Arch Linux, not a minimal/Debian-ish base: gw-shell / gw-ls / zoe are
# dynamically linked against glibc (see `ldd`), and Arch's glibc is at
# least as new as the one they were built against on the host -- an older
# distro's glibc can be missing symbol versions those binaries want. Using
# the same base family sidesteps that entirely rather than chasing it.
FROM archlinux:base

RUN pacman -Syu --noconfirm --needed openssh shadow && \
    pacman -Scc --noconfirm && \
    ssh-keygen -A && \
    mkdir -p /run/sshd

# A fixed, published password -- this is a local-only test target
# (started with a container-only port mapping, torn down when you're
# done), never something reachable from outside your machine. Real
# credentials never belong here.
RUN useradd -m -s /bin/bash glyphwire && \
    echo 'glyphwire:glyphwire' | chpasswd

# Both auth paths stay open: password (to exercise `glyphwire`'s
# SSH_ASKPASS-driven in-window prompt) and pubkey (for a quiet
# already-authenticated connection -- see run-remote-test-container.sh's
# authorized_keys mount).
RUN sed -i \
    -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
    -e 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' \
    -e 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
    /etc/ssh/sshd_config

# `dist/` is `zig build install-local`'s output (see
# build-remote-test-image.sh) -- the same relocatable
# bin/ + share/glyphwire/ layout a real install uses, so path resolution
# (zoe's grammars, gw-agent finding a sibling gw-shell) behaves exactly as
# it would on a real remote box.
COPY dist/bin/ /usr/local/bin/
COPY dist/share/glyphwire/ /usr/local/share/glyphwire/

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
