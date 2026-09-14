<!-- SPDX-License-Identifier: CC-BY-4.0 -->
# Contributing to glyphwire

Thanks for looking. glyphwire is pre-1.0 and moving quickly; the fastest
way to have a change accepted is to open an issue describing it before
writing much code.

**Before your first pull request, read [`CLA.md`](CLA.md).** Contributions
are accepted under a Contributor Licence Agreement that assigns copyright
to the maintainer, so the project stays relicensable by a single decision.
It grants your own work back to you under Apache-2.0, so it costs you
nothing you had before. Signing is two lines in a commit — see
[Signing off](#signing-off).

Bug reports, reproduction cases, design feedback and documentation
corrections need **no agreement at all**. If you can't sign the CLA, those
are still very welcome.

## Getting set up

glyphwire pins an exact Zig version, matching `build.zig.zon`'s
`minimum_zig_version` and CI:

```
0.17.0-dev.1857+3c46da14d
```

Newer or older Zig will not build this tree. The dev build is pruned from
`ziglang.org`; the community mirrors still carry it, and
[`scripts/bootstrap-linux.sh`](scripts/bootstrap-linux.sh) verifies the
version and primes the cache for you:

```sh
./scripts/bootstrap-linux.sh      # or: just bootstrap
```

Nothing else is needed. Every dependency is fetched or vendored in-tree,
`host_eng/` is glyphwire's own engine backend, and SDL3 is built from
source and `dlopen`s X11 / Wayland at runtime — so there are no system
`-dev` packages to install. You do need a working OpenGL setup to *run*
the host.

```sh
zig build                 # every executable into zig-out/bin/
zig build tests           # the full suite            (just test)
zig build glyphwire       # build + run the host, which spawns gw-shell
zig build package         # only the shipped programs, grammars and assets
```

## Tests

**Every pull request must keep `zig build tests` green.** It is currently
937 tests and takes about eight seconds; there is no excuse for skipping
it.

```sh
zig build tests            # everything
zig build tests -- core    # just one group        (just test core)
zig build tests -- --groups        # list the group tags
zig build tests -- -v core         # verbose, one group
```

The group filter is a bare tag, not a flag. `--groups` prints every
available tag; `--help` lists the rest of the runner's options.

Tests live in [`tests/`](tests/), one file per group, registered in
[`tests/main.zig`](tests/main.zig):

```zig
testz.Group{ .name = "Core Tests", .tag = "core", .mod = @import("./core_tests.zig") },
```

A test is a `pub fn somethingTest() !void`. Adding a new group means a new
file plus one row in that table.

Pure logic belongs in a `*_support` module (`shell/support.zig`,
`ls/support.zig`, `host/support.zig`, `zoe/support.zig`,
`gmux/support.zig`) so the test runner can exercise it without linking SDL
or opening a socket. If you find yourself unable to test something because
it needs a window, that is usually a sign the logic wants extracting.

CI runs `zig build package -Doptimize=ReleaseSafe` on every push and pull
request via [`.github/workflows/linux-package.yml`](.github/workflows/linux-package.yml).

## Licensing rules for new code

glyphwire is split across three licences. **Which licence your patch lands
under is decided by the directory you put it in**, not by you — see
[`LICENSE.md`](LICENSE.md) for the full map.

| Directory | Licence |
|---|---|
| `src/`, `host/`, `host_eng/`, `server/`, `client/`, `agent/`, `notify/`, `debug/`, `demo/`, `table-demo/` | `MPL-2.0` |
| `shell/`, `gmux/`, `ls/`, `view/`, `zoe/`, `tests/` | `GPL-3.0-or-later` |
| `docs/`, `README.md` | `CC-BY-4.0` |

Three rules follow from that, and a pull request breaking any of them will
be sent back:

**1. Every new source file needs an SPDX header** matching its directory,
as the first two lines:

```zig
// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: MPL-2.0
```

A `//!` module doc comment goes *after* it; Zig accepts a plain comment
before one.

**2. No MPL file may import a GPL module.** The dependency graph runs one
way only. Nothing in `src/`, `host/`, `host_eng/`, `server/`, `client/`,
`agent/`, `notify/`, `debug/`, `demo/` or `table-demo/` may reach into
`shell/`, `gmux/`, `ls/`, `view/` or `zoe/`. The GPL programs linking the
MPL core is fine and deliberate; the reverse would make the MPL core
undistributable as MPL.

**3. Never add MPL-2.0's Exhibit B** ("Incompatible With Secondary
Licenses") to any file. That notice is what currently lets the GPL programs
link the MPL core. Adding it breaks every GPL binary in the repo.

### Moving code between licence zones

Code is expected to move — extracting a library out of an application is
the most likely direction, and `GPL-3.0-or-later` → `MPL-2.0` is the safe
one. It grants more rights than before, so nobody loses anything and no
announcement is needed. Versions already published keep their old terms
permanently, which costs nothing here: the MPL version supersedes them.

The move itself is four steps.

1. **Move the file**, and update its SPDX header to the destination zone in
   the same commit. `git mv` carries the old header along, and a header
   that disagrees with `LICENSE.md` is worse than no header — a downstream
   vendor reads the header, not the table.
2. **Shed any GPL imports.** A file that lands in an MPL directory may no
   longer reach into `shell/`, `gmux/`, `ls/`, `view/` or `zoe/`, whether by
   module name or relative path. If it depends on something that is still
   GPL, move that dependency first — a thing two applications both import
   is usually library code anyway, which is the signal it wanted extracting.
3. **Update `LICENSE.md`** if you added or removed a directory, and
   `build.zig` if the module's `root_source_file` moved.
4. **Run the checker** (below).

Leave git history alone. It will show the file as GPL before the move and
MPL after, which is the correct record of what was licensed when. There is
nothing to rewrite.

If a file is genuinely shared and you would rather not restructure, an
alternative to moving it is dual-licensing it in place
(`SPDX-License-Identifier: MPL-2.0 OR GPL-3.0-or-later`). Prefer a move
when you are extracting a real library; the zone map stays easier to read.

### Checking it

```sh
zig build check-licenses          # or: scripts/check-licenses.py
```

It verifies that every source file's SPDX header matches its directory's
zone, that no MPL file imports a GPL module, that no file carries MPL
Exhibit B, and that the licence texts are present. It needs no compilation
and runs in well under a second, and CI runs it on every push and pull
request.

Module licences are derived from where each module's `root_source_file`
lives in `build.zig`, not hardcoded — so moving `ls/support.zig` into
`src/` reclassifies the `ls_support` module automatically, with no edit to
the checker. If you add a new top-level directory, add it to `ZONES` in
[`scripts/check-licenses.py`](scripts/check-licenses.py) and to
[`LICENSE.md`](LICENSE.md).

**New dependencies** need a permissive licence (MIT, BSD, Zlib, Apache-2.0,
public domain) and a row in [`THIRD-PARTY.md`](THIRD-PARTY.md). A copyleft
dependency in an MPL directory is a non-starter. Say why the dependency
earns its place — this project vendors a lot rather than taking on
transitive risk.

## Code conventions

Match the file you are editing; it is a more reliable guide than any list.
Broadly:

- **`zig fmt` before committing.** No exceptions.
- **Explicit over clever.** If a reader has to reconstruct your reasoning
  to be sure the code is right, write the reasoning down instead.
- **Comments explain *why*.** The existing code is heavily commented and
  those comments carry the design rationale — why a lock is held where it
  is, why a handle is checked twice. Match that density. Do not narrate
  what the code plainly says.
- **Keep `src/` policy-free.** The protocol core takes no view on fork/exec
  policy, window management or asset paths; those are injected by the host
  (see `Server.setPaneSpawner`). A pull request that grows policy in `src/`
  will be asked to invert it.

## Protocol changes

The wire protocol has a normative specification:
[`docs/protocol.md`](docs/protocol.md).

If your change adds, removes or alters a message, a parameter, a result
shape, a notification, a subscription stream or an error code, **update the
spec in the same pull request.** A protocol change that ships without a
spec change is a bug, because other people write clients against that
document.

The four documents divide as follows:

| Document | Holds |
|---|---|
| [`docs/protocol.md`](docs/protocol.md) | The normative spec. What an implementer must do. |
| [`docs/api.md`](docs/api.md) | The catalog annotated with per-message implementation status and behaviour. |
| [`docs/decisions.md`](docs/decisions.md) | *Why* each shape was chosen. Design rationale, not reference. |
| [`docs/roadmap.md`](docs/roadmap.md) | The running implementation log. |

A substantial change usually touches `decisions.md` (the reasoning) and
`roadmap.md` (the record) as well as the code.

Bear in mind the protocol is CC-BY-4.0 and meant to be implemented by
people who will never read this repository. Write for them.

## Commits and pull requests

**Commit subjects are written in the past tense**, describing what the
commit did:

```
Added panes: a window split tree whose leaves hold whole contexts
Fixed gmux's config arena being copied before it was allocated through
Rewrote gmux as a pure window manager
```

Not `Add panes` or `Fix arena`. This is the convention throughout the
history; please match it.

Use the body to explain *why*, especially for anything non-obvious. The
existing log has long, substantive commit bodies and they have repeatedly
proved worth writing.

**Do not add `Co-authored-by:` trailers, or attribution to any AI tool, to
commits or pull requests.** If you used an assistant to write a patch, that
is fine and needs no disclosure — but you are the contributor, you are
representing under CLA section 6 that you have the right to submit it, and
you are responsible for every line. Review it as if you had typed it.

Before opening a pull request:

- `zig fmt` is clean
- `zig build tests` passes
- `zig build check-licenses` passes (new files carry the right SPDX header,
  and no MPL file imports a GPL module)
- the protocol spec is updated if the wire changed
- you are in `CONTRIBUTORS.md`, if this is your first contribution

Keep pull requests focused. A refactor and a behaviour change in one branch
is two pull requests.

## Signing off

On your **first** contribution, add yourself to
[`CONTRIBUTORS.md`](CONTRIBUTORS.md) in the same pull request:

```
- Ada Lovelace <ada@example.com> — agreed to CLA v1.0
```

On **every** commit, add the trailer:

```
Glyphwire-CLA: 1.0 signed-off-by Ada Lovelace <ada@example.com>
```

Together these are your signature on [`CLA.md`](CLA.md). There is no form
and nothing to email.

## Reporting a security issue

Do not open a public issue. Email the maintainer directly and allow a
reasonable window before disclosure.

## Questions

Open an issue. "Would you accept a change that does X?" is a perfectly good
one to ask before writing it, and will save you time.
