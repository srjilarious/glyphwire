# Licensing

Copyright (c) 2026 Jeff DeWall

glyphwire is deliberately split across three licenses so the parts meant to
be *embedded* stay embeddable, the parts that are *end-user applications*
stay free, and the *protocol* stays open for anyone to implement.

| Part | License | SPDX |
|---|---|---|
| The wire protocol specification | Creative Commons Attribution 4.0 International | `CC-BY-4.0` |
| Protocol core, host, engine backend, server, client library, tooling | Mozilla Public License 2.0 | `MPL-2.0` |
| The end-user applications (`gw-shell`, `gmux`, `gw-ls`, `gw-view`, `zoe`) | GNU General Public License v3.0 or later | `GPL-3.0-or-later` |

Full texts live in [`LICENSES/`](LICENSES/). Every source file carries an
`SPDX-License-Identifier` line, so a single directory can be vendored
without consulting this table.

## Why three

**The protocol is documentation, not code.** [`docs/protocol.md`](docs/protocol.md)
is the normative specification: framing, envelope, object model, message
catalog. It is CC-BY-4.0 so anyone can write a client, a host, or a
competing implementation in any language and under any license, with only
attribution asked in return. Nothing in the code licenses reaches an
independent implementation of the spec.

**The plumbing should be embeddable.** The protocol core, the display
server, the reference host and its engine backend, and the Zig client
library are MPL-2.0: file-level copyleft. A proprietary or differently
licensed product can link, ship, and embed these unmodified, and only owes
source for the MPL files it actually changes.

**The applications are applications.** The shell, the multiplexer, the
lister, the viewer, and the editor are programs people run, not components
people embed. They are GPL-3.0-or-later.

## What is under what

### `CC-BY-4.0`

| Path | |
|---|---|
| `docs/` | the protocol specification, design decisions, roadmap, investigations |
| `README.md` | |

### `MPL-2.0`

| Path | Produces |
|---|---|
| `src/` | the `glyphwire` module: protocol core, wire framing, JSON-RPC dispatch, server, client library, pty and mux |
| `host/` | `glyphwire` — the reference display host |
| `host_eng/` | glyphwire's in-tree SDL3 / OpenGL backend |
| `server/` | `glyphwire-server` — the headless server |
| `client/` | `glyphwire-client` — reference socket client |
| `agent/` | `gw-agent` — the remote-session trunk agent |
| `notify/` | `glyphwire-notify` |
| `debug/` | `glyphwire-probe` |
| `demo/`, `table-demo/` | `glyphwire-demo`, `glyphwire-table-demo` |
| `build.zig`, `build.zig.zon`, `packaging/`, `scripts/`, `docker/` | build and packaging |

### `GPL-3.0-or-later`

| Path | Produces |
|---|---|
| `shell/` | `gw-shell` — the glyphwire-aware shell |
| `gmux/` | `gmux` — the window multiplexer |
| `ls/` | `gw-ls` — the directory lister |
| `view/` | `gw-view` — the file viewer |
| `zoe/` | `zoe` — the modal editor |
| `tests/` | the test runner, which links all of the above |

`tests/` is GPL-3.0-or-later because it links the GPL modules; it is a
development tool and is not installed.

### Not ours

`libs/`, `vendor/`, `host_eng/libs/`, and `assets/` hold third-party code
and data under their own licenses, unchanged. See
[`THIRD-PARTY.md`](THIRD-PARTY.md). Files in those directories carry no
glyphwire SPDX header.

## Notes for people combining these

**MPL and GPL mix here on purpose.** `zoe`, `gw-ls`, `gw-view`, `gw-shell`
and `gmux` are GPL programs that link the MPL `src/` module. That is
explicitly permitted: MPL-2.0 §3.3 allows an MPL file to be distributed as
part of a Larger Work under the GPL, because none of glyphwire's MPL files
carry the Exhibit B "Incompatible With Secondary Licenses" notice, and none
ever should. Removing that guarantee would break every GPL binary in this
repo.

**The dependency graph only runs one way.** No MPL directory imports a GPL
one. `zoe/` reuses `ls/`'s icon mapping, which is GPL importing GPL. If you
add a dependency, keep that direction: an MPL file may never import from
`shell/`, `gmux/`, `ls/`, `view/`, or `zoe/`. `zig build check-licenses`
enforces this, along with every file's SPDX header; CI runs it on every
push. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the procedure when code
moves between zones.

**Embedding the host is an MPL question, but the assets are not.** The
default icon theme shipped in `assets/icons/filetype/oxygen/` is LGPL-3.0,
and `assets/icons/filetype/papirus/` is GPL-3.0. They are data files the
host reads at runtime, not linked code, but they are still copyleft and
travel with their own terms. A product embedding the host that wants no
copyleft assets should ship the MIT-licensed Material theme instead and set
`icon_theme = "material"` in `host.conf.lua`. See
[`THIRD-PARTY.md`](THIRD-PARTY.md).

**Implementing the protocol carries no code obligation.** Reading
`docs/protocol.md` and writing your own host or client obliges you to
attribute the specification and nothing more.

## Contributions

Contributions are accepted under the
[Contributor Licence Agreement](CLA.md), which assigns copyright in a
contribution to the maintainer (with a fallback exclusive licence where
local law does not permit assignment), and licenses the contribution back
to its author under Apache-2.0.

The point is to keep the whole codebase relicensable by a single decision:
this three-way split is a choice, not a permanent one, and it can only be
revisited while one person can speak for every line. See
[`CONTRIBUTING.md`](CONTRIBUTING.md).

Note that relicensing is always forward-looking. Every version already
published under MPL-2.0, GPL-3.0-or-later or CC-BY-4.0 stays available
under those terms permanently; all three grants are irrevocable.
