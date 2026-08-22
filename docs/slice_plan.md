# Vertical Slice Plan

Goal: prove server, shell, and a test client talking over the **simplest
real subset** of the protocol, end to end — a test program writes
`"hello"` with no positioning, and that lands in inspectable server state.
Headless only; no rendering yet.

## Explicitly out of scope for this slice

Cutting these on purpose so the first working thing stays small:

- Capability negotiation/handshake (the baseline tier needs none — see
  DECISIONS.md, Protocol Shape).
- Multiple contexts / context switching (one context, created at server
  startup).
- Images, icons, animation, input events, action maps.
- Layer tree nesting beyond the root layer.
- Style attributes beyond plain fg/bg color.
- Real Unicode grapheme segmentation (UAX #29) — start with a naive
  splitter, swap in the real thing later without changing the slice's
  shape.

Every one of these has a place already staked out in DECISIONS.md; none
of them are being designed away, just deferred past "does the pipe work."

## Milestones

**1. Headless core state (Zig, no I/O).**
Implement `Context`, `Layer`, `Cell` per the Object Model in
DECISIONS.md: one `Context` containing one root `Layer`, sized from a
configurable width/height. `write_text_to_layer(layer, text, style)`
appends grapheme clusters at the layer's cursor and advances/wraps it
(naive UTF-8 splitting for now). `get_property`/`set_property` implemented
at least for `cursor`. Unit tests assert directly on the struct — e.g.
after writing `"hello"`, `layer.cells[0][0].grapheme == "h"` and
`layer.cursor == {row: 0, col: 5}` — with no networking involved. This is
the actual proof that the headless-first requirement holds, and it should
exist before a single socket is opened.

**2. Wire framing module.**
`Content-Length`-prefixed JSON-RPC-style read/write, tested against an
in-memory byte pipe rather than a real socket: encode a request, decode
it back, handle a partial read/reassembly case. Kept as its own module
with its own tests, independent of the core state from step 1.

**3. Minimal message dispatch (still no real socket).**
Wire framing + headless core, driven by an in-process test harness: feed
an encoded `write_text` message in, assert the decoded response and the
resulting core state. This is where the *message catalog subset* for the
slice gets nailed down concretely — just enough of `write_text` and
`get_property`/`set_property` to make step 7's assertion possible,
nothing else from the fuller catalog yet.

**4. Socket server.**
Wrap step 3 in a real Unix domain socket listener: accept, read frames,
dispatch, write frames back. One context is created automatically at
startup — no `create_context` yet. This is the first point real
inter-process communication exists.

**5. Minimal shell (launcher).**
A small program that starts or connects to the server, sets
`GLYPHWIRE_SOCK` and `GLYPHWIRE_CTX` in the environment, and execs a
child command given on its own argv. Doesn't need to be an interactive
shell yet — just enough to prove the discovery mechanism end to end.
Worth building this in Zig rather than a throwaway script, since it's the
seed of the real shell later.

**6. Test client.**
The smallest possible program that checks for `GLYPHWIRE_SOCK`, connects,
sends `write_text("hello")` with no `row`/`col`, and exits. Prove both
paths, not just the happy one: env var present (message goes through) and
env var absent (fallback message to stdout, clean exit, no crash) — the
fallback behavior is the whole point of the discovery mechanism and is
cheap to verify now rather than assumed.

**7. End-to-end proof.**
Run shell → test client, then confirm from the outside (a second small
inspector call to `get_property(root_layer, "cursor")`, or a headless test
harness that drives the whole pipeline in-process) that the root layer's
cell buffer contains `"hello"` starting at `(0, 0)` and the cursor sits at
`(0, 5)`. This is the concrete "it works" milestone.

**8. Next, not part of this slice.**
Wire the existing Zig 2D engine to actually render the root layer's cells
to a window. The slice's success criterion is the protocol and headless
state working end to end, not pixels on screen — rendering is a natural
follow-on milestone once this is solid.

## Open question for this plan

What language to write the test client in for fastest iteration — Zig
throughout for consistency with the server/shell, or a scripting language
(e.g. Python) for the client specifically, since it's disposable and the
whole point of the "no linking" design is that any language should be
able to speak the protocol with nothing but a socket and a JSON encoder.
Using a non-Zig client for step 6 would also double as an early real-world
test of that claim.

  - We'll use zig for the server, shell, unit tests (use testz library)
  - client test program will also start off as zig.  As a post-step we'll make a ffi library and python bindings and have tests for both directly sending a message as well as using the ffi library to make it cleaner.
