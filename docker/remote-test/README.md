# Remote-session test container

A disposable "remote box" for exercising `glyphwire --ssh <dest>`
(see docs/decisions.md's "Remote sessions" section) without a second
machine: an Arch Linux container running sshd, with this tree's
`gw-agent` / `gw-shell` / `gw-ls` / `gw-view` / `zoe` installed the same
way `zig build install-local` installs them anywhere else.

## Build and run

```sh
./scripts/build-remote-test-image.sh     # zig build install-local + docker build
./scripts/run-remote-test-container.sh   # docker run, prints the glyphwire command
```

The run script mounts your own `~/.ssh/id_ed25519.pub` (or `id_rsa.pub`)
in as `authorized_keys` if it finds one, so pubkey auth logs straight in.
Skip that (or force it off with `-o PreferredAuthentications=password` in
the extra ssh args) to exercise glyphwire's in-window `SSH_ASKPASS`
password prompt instead -- the container's login is `glyphwire` /
`glyphwire`.

## Re-testing a code change

Rebuild the image (`build-remote-test-image.sh` again) after any change
to `agent/`, `shell/`, `ls/`, `view/`, `zoe/`, or their shared support
code, then restart the container (`run-remote-test-container.sh` again --
it replaces the old one). The host-side `glyphwire` binary you're running
`--ssh` from is a separate build; rebuild it the normal way.

## Notes

- The container's host key regenerates on every rebuild, so the printed
  command points ssh at `/dev/null` for `UserKnownHostsFile` and
  auto-accepts new keys -- never your real `known_hosts`. To try the
  host-key-confirmation prompt itself, drop `StrictHostKeyChecking` and
  point `UserKnownHostsFile` at a scratch file instead so the "yes/no"
  prompt actually fires.
- The `glyphwire:glyphwire` login is fixed and only ever reachable via
  `127.0.0.1:<port>` (see the run script's port mapping) -- fine for a
  disposable local target, never meant to be exposed further.
- `docker rm -f glyphwire-remote-test` tears it down; nothing it writes
  persists across a restart.
