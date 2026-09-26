# LSP in zoe

Design note, 2026-09-26. What it would take to put language servers behind
zoe -- `zls` for Zig, `basedpyright` + `ruff server` for Python -- and what
the first slice actually implements.

Slice 1 carries one protocol change with it: underline styles, including
the curly one, because the alternative was a diagnostic mark made of colour
competing with the syntax colour it sits on. See
[Drawing diagnostics](#drawing-diagnostics).

## What already exists

zoe is unusually close to this, because four of the pieces LSP needs are
already in the tree and already have owners:

- **The framing is ours already.** glyphwire's own wire format *is* LSP
  framing -- `Content-Length: n\r\n\r\n` then `n` body bytes -- and
  `glyphwire.wire.FrameDecoder` (`src/wire.zig`) is an incremental decoder
  for exactly that, fed arbitrary-sized chunks. An LSP server's stdout is
  the same byte stream a glyphwire connection carries. No new framing code.
- **JSON is already in the build.** `src/dispatch.zig` parses JSON-RPC with
  `std.json` and `parseFromValue` into typed param structs. LSP messages
  get the same treatment. No new dependency for any of this -- not for
  framing, JSON, processes or threads.
- **Per-buffer language state is already a thing.** `Slot.hl` is a
  tree-sitter `Highlighter` per open buffer, keyed off the extension ->
  grammar map (`syntax.LangDef` / `default_langs`). LSP keys off the same
  map, so "which server does this buffer talk to" is answered where "which
  grammar highlights it" already is.
- **Overpainting a byte range in a row is already a helper.**
  `Ui.paintRowSpan` is what the search highlight and the visual selection
  both go through: give it a row, a byte range and a colour and it clips to
  the horizontal scroll and repaints. Diagnostics are a third caller.

What does *not* exist, and is the substance of the work: a long-lived child
process whose output arrives at times the UI did not ask for.

## The event-loop problem, and `InputListener.wake`

`Ui.run` blocks outright:

```zig
const first = try self.listener.next(.none) orelse continue;
```

That is the right shape -- every host notification wakes it, so zoe never
polls on a timer -- and it is exactly what a language server breaks. A
`publishDiagnostics` arriving three seconds after the last keystroke has no
host notification behind it, so it would sit in a queue until the user
happened to press a key.

gw-read already has one answer: `read/ui.zig` shortens the wait to 20ms
while an AI or Anki job is in flight (`io.concurrent` + an atomic `done`).
That is right for a request with a beginning and an end, and wrong here. An
attached server is attached for the whole session, so the same trick means
zoe wakes 50 times a second forever as soon as a `.zig` file is open, for a
stream that is idle almost all of that time.

**Decision: add `InputListener.wake()`** -- about fifteen lines in
`src/client.zig`. The reader thread calls it; a blocked `next` returns
`null` once, which `run`'s `orelse continue` already handles as "go round
again"; and `run` drains the LSP inbox at the top of the loop next to the
render-dirty checks. zoe stays fully event-driven with no latency floor,
and any future background worker in any client gets the same door.

Mechanically: an atomic `woken` flag on the listener, set before
`sem.post`, checked in `waitFirst`'s loop after `takeFirst` comes up empty.
It has to be a flag and not a bare `post`, because `waitFirst` loops on an
empty queue and would otherwise go straight back to waiting.

The debounce timer (below) is the one thing that still wants a timeout, and
it is transient like gw-read's: while a `didChange` is armed, wait at most
until it fires.

## Process and thread model

One `lsp.Server` per (workspace root, server) pair, holding:

- the child (`std.process.spawn`, `stdin`/`stdout` pipes, `stderr` to
  `.ignore` for now),
- a `std.Thread` reader -- the same shape as `Client.listen_thread` in
  `src/client.zig`, which is the precedent for "a thread whose only job is
  to turn a socket into queued messages",
- a mutex-guarded inbox of parsed messages, drained by the UI thread,
- an in-flight table mapping request id -> what the response is for
  (`.hover`, `.definition`, ...), so a reply can be routed without the UI
  having stored a continuation.

The UI thread never reads from the pipe and the reader thread never touches
a `Slot`, a layer or the `Client`. Everything crosses at the inbox. Writes
(requests, `didChange`) go straight out on the UI thread under a write
mutex -- they are small and the pipe buffer absorbs them; a blocking write
to a wedged server is the one place this could stall, and the mitigation is
the same as a wedged host: bounded, then the server is marked dead.

Not `io.concurrent`: a future that never resolves for the life of the
session is not what that abstraction is for.

## Which servers

Built-in defaults, each started only if its binary is on `PATH`, merged by
name with whatever `zoe.conf.lua` says:

| language | server | command | why |
| --- | --- | --- | --- |
| zig | zls | `zls` | the only real option, and it speaks `positionEncoding: utf-8` |
| python | basedpyright | `basedpyright-langserver --stdio` | the 2026 open-source Pylance-equivalent: closest to feature parity with no license restriction, largest contributor base of the forks, pip-installable |
| python | ruff | `ruff server` | lint and format diagnostics, native, fast; pairs with a type checker rather than replacing one |

Two servers on one filetype is the point, not an edge case -- the standard
Python setup in 2026 is a type checker for navigation and hover plus
`ruff server` for lint squiggles. So the registry is a *list* per language
from the first line of code, diagnostics are stored and replaced per
`(uri, server)` rather than per `uri`, and a capability query is "which
attached server can do `hover`" rather than "can the server do `hover`".
Single-server assumptions are cheap to write and expensive to unpick, and
`ty` / `pyrefly` landing later should be a config edit, not a refactor.

## Position encoding: the trap

LSP positions are **UTF-16 code units** by default, not bytes and not
columns. zls negotiates `utf-8` happily; basedpyright, being pyright
underneath, is utf-16. So this is not a "pick one" -- both encodings ship,
the client advertises `general.positionEncodings: ["utf-8", "utf-16"]`,
whatever the server picks in its `initialize` result is stored *per server*,
and every position crossing the boundary goes through a conversion keyed on
that field.

Getting this wrong is invisible in ASCII and then silently off-by-N on any
line with a non-ASCII character in it -- a comment with a Japanese word in
it, an em dash, an emoji in a string. It gets unit tests in the first
slice, not the third.

Three coordinate systems meet here and the conversions are named for it:
buffer bytes (zoe's native), LSP line/character, and display columns
(`zoe/display.zig`, tabs expanded). Diagnostics arrive in the second and
are painted in the third.

## Document sync

**Full text, debounced 150ms.** `didOpen` on open with the whole buffer,
`didChange` with the whole buffer, `didClose` on `:bd`, `didSave` on `:w`
(ruff and zls both have things to say on save).

Incremental sync is the obvious thing to want, and `Buffer.pending_edits`
is already the right data -- start/old-end/new-end in both bytes and
points, exactly what `textDocument/didChange` ranges need. The problem is
that the journal has *one* consumer today: `renderBuffer` drains it with
`clearEdits()` after the highlighter replays it. A second consumer means
either per-consumer cursors or a reference count, and that is a change to
the buffer's contract for a bandwidth win on a local pipe. Deferred, with
a note: `buf.edits` (monotonic, never reset) is the trigger, and the
debounce means a burst of typing is one message either way.

## Drawing diagnostics

`core.Style` was colour-only by decision: bold, italic, underline and
strikethrough were parsed out of SGR and thrown away, and first-class
`Style` fields for them were decided-not-wired.

That was the right call for the attributes that need font work, and the
wrong one for underline, which is why slice 1 adds it. The reason is
specific: a diagnostic mark has to survive *on the same cell as* a syntax
colour and under a selection tint. A mark made of foreground colour fights
the highlighter, and a mark made of background colour fights the selection
and the search highlight; both lose information the moment they overlap. An
underline is a third channel on the cell, which is exactly what is needed,
and unlike bold or italic it is drawn from geometry the host already has --
a rect at the baseline, no second font face in the atlas.

So the protocol now carries, on `write_text` and its spans:

- `underline`: `"none"` (default), `"single"`, `"double"`, `"curly"`,
  `"dotted"`, `"dashed"` -- the SGR `4:1`..`4:5` set, so the escape
  sequences map onto it one-to-one instead of being a glyphwire invention.
- `underline_color`: independent of `fg`, defaulting to it. This is the
  half that makes a red squiggle under white text possible, and it is SGR
  `58`/`59`.

It also needed a second, less obvious wire op: **`set_underline`**, which is
`set_bg` for the underline channel. A row in zoe is painted as coloured runs
and *then* overpainted with the search highlight and the visual selection,
and each of those is a full cell write that resets the underline. So a
squiggle threaded through the row's own writes is erased by the next
selection, and threading it through all of them means every overpaint — and
every future one — knowing about diagnostics. One `set_underline` after them
means none of them do. `set_bg` exists for the same shape of reason, which is
the argument for the op rather than a reason to avoid it.

Two consequences worth knowing about:

- **The SGR tokenizer now remembers its separators.** `4:3` is a curly
  underline and `4;3` is an underline plus an italic, and the parser used
  to collapse `:` and `;` because in `38`/`48` colours the two spellings
  mean the same thing. Left alone, every `ESC [ 4;3 m` in a mirrored
  program's output would have become a squiggle.
- **The repeating styles take their phase from the cell's absolute window
  position**, so a curly underline across a word is one continuous wave
  rather than a row of identical per-cell marks.

Bold, italic, strikethrough and dim stay unwired. Nothing changed about
why: they need font faces, not a rect.

On top of that, slice 1 draws diagnostics as:

1. **The squiggle itself** -- a `curly` underline in the severity's colour
   over the diagnostic's range, painted through the row painter.
2. **A sign column**, one cell wide, left of the line numbers: a coloured
   mark for the worst severity on that line. The squiggle shows *where*;
   the sign survives horizontal scrolling and shows *that*.
3. **The message in the statusline** when the cursor is on a diagnostic,
   with its source prefixed (`basedpyright: ...` vs `ruff: ...`), because
   with two servers on one file "which tool is complaining" is half the
   information.
4. **`]d` / `[d`** to step to the next/previous diagnostic in the buffer,
   and `:diag` to list them.

Storage is a per-buffer store keyed by `(uri, server)`, with a line-indexed
view so the row painter asks "what is on line N" and gets an answer without
scanning. A server republishes the whole set for a file, so replacement is
by whole `(uri, server)` set -- no merging of individual entries.

## Hover and goto-definition

**`K` -- hover.** `textDocument/hover` at the cursor, rendered into a
bordered float. The finder popup (`Ui.finder`, two layers outside the split
tree, hand-positioned, hidden when idle) is the precedent and the
machinery. Hover content is markdown; slice 1 strips it to plain text with
code fences kept verbatim. Rendering it properly means the `md/` zmd
renderer, which is a later slice.

**`gd` -- goto-definition.** `textDocument/definition`. `g` is already a
prefix in `editor.zig` (`prefix = 'g'` for `gg`, `gv`), so this is another
case in an existing switch. Same buffer: move the cursor. Another file:
`Ui.openFile` then move. There is no jumplist in zoe today, so slice 1 adds
a minimal one -- a bounded stack of (path, byte offset) with `Ctrl+O` /
`Ctrl+I` -- because `gd` with no way back is a trap for anyone with the
muscle memory.

Neither blocks. The request goes out, the statusline shows that it is out,
the response arrives in the inbox and is applied whenever it lands. A
response carries its own target, so a cursor that moved in the meantime
does not invalidate it; a *stale* one (the user already jumped somewhere
else) is dropped by comparing the in-flight id against the newest.

## Failure modes

Every one of these is "a language server is not part of the editor's
correctness":

- **Binary missing** -- no server, nothing logged at startup, and `:lsp`
  says so on request. Most people do not have all three installed.
- **Server crashes** -- marked dead, one line in the statusline,
  diagnostics for its files cleared. No automatic respawn loop; `:lsp
  restart` is the recovery. A server that crashes on a file will crash on
  it again, and a respawn storm is worse than a dead server.
- **Server wedges** -- requests time out (a few seconds) and the in-flight
  entry is dropped. The editor never waits on one.
- **`initialize` fails or handshake times out** -- treated as "missing".
- **Exit** -- `shutdown` then `exit`, a bounded wait, then kill. zoe's own
  quit path does not hang on a child.

`stderr` goes to `.ignore` in slice 1. A ring buffer behind `:lsp log`
would earn its keep the first time zls has something to say, and is a
one-file addition later.

## Roots

One server instance per workspace root, where the root is zoe's cwd -- zoe
already `cd`s into a directory argument, so the cwd *is* the project. Files
opened from outside the root go to the same instance rather than spawning a
second; LSP permits it and both zls and basedpyright handle it. `:cd` does
not re-root a running server in slice 1.

## Configuration

Mirrors `config.languages`: a list of tables in `zoe.conf.lua`, parsed in
`zoe/langconf.zig` (which is where config parsing lives precisely so
`tests/zoe_tests.zig` can exercise it with no client attached), merged with
the built-ins **by name** so that overriding one server does not mean
re-declaring the others.

```lua
config = {
    lsp = {
        -- Master switch. false stops any server from starting.
        enabled = true,

        servers = {
            -- Same name as a built-in overrides it, field by field.
            { name = "zls", cmd = { "zls" } },

            -- enabled = false disables a built-in without redeclaring it.
            { name = "ruff", enabled = false },

            -- A new name adds a server.
            { name = "ty", languages = { "python" }, cmd = { "ty", "server" } },

            -- Passed through as initializationOptions.
            {
                name = "basedpyright",
                settings = {
                    python = { analysis = { typeCheckingMode = "standard" } },
                },
            },
        },
    },
}
```

`languages` are the grammar names `syntax.default_langs` already uses
(`zig`, `python`, `c`, `lua`, ...), which double as LSP `languageId`s for
the ones that matter; the handful that differ (`bash` -> `shellscript`)
come from a small override table.

## Files

| file | what |
| --- | --- |
| `zoe/lsp.zig` | `Server`: spawn, framing over `wire.FrameDecoder`, reader thread, inbox, request correlation, capabilities, position-encoding conversion. `Pool`: the per-root registry and the "which server can do X for this buffer" query. |
| `zoe/diag.zig` | the diagnostic store -- per `(uri, server)` sets, line-indexed lookup, severity ordering, next/previous. |
| `zoe/langconf.zig` | `config.lsp` parsing and the built-in server table. |
| `zoe/ui.zig` | inbox drain in `run`, sign column in the gutter, squiggle in the row painter, statusline message, `K` / `gd` / `]d` / `[d` / `:lsp` / `:diag`, the jumplist. |
| `src/client.zig` | `InputListener.wake()`, and `underline` on `TextOpts`/`Span`. |
| `src/core.zig` | `Underline` / `UnderlineStyle`, `Style.underline`, the SGR underline codes and the separator-aware tokenizer. |
| `src/dispatch.zig`, `src/protocol.zig` | `write_text`'s `underline` / `underline_color`, the `set_underline` op, and `get_cells` reading them back. |
| `host/render.zig` | the underline batch, drawn over the glyphs, and the five styles' geometry. |
| `tests/zoe_tests.zig` | framing + correlation against a canned stream, utf-8/utf-16 position conversion, the diagnostic store's index and per-source replacement, config parsing. |

No live server in the test run -- that is an `e2e` shape and `e2e` is
already the flaky group. The transport is tested against bytes, not against
an installed zls.

## Phasing

- **Slice 1 (this round)** -- lifecycle, document sync, diagnostics, hover,
  goto-definition, jumplist, `InputListener.wake`, config, tests.
- **Slice 2** -- completion. The insert-mode popup is the biggest UI piece
  in the whole feature and deserves its own round; the finder is the
  precedent for the popup and the wrong precedent for the filtering.
- **Slice 3** -- references, rename, formatting, code actions, signature
  help. Rename is multi-file edits, which wants the undo groups to span
  buffers.
- **Slice 4** -- incremental sync (needs the journal's second consumer),
  markdown hover through `md/`, `:lsp log`.
