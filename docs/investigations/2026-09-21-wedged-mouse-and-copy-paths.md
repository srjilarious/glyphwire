# salacommander over `gwssh`: why clicks died, and where copy-paths went

Two things landed together (`d95edfd`) because the same setup turned both
up: salacommander running on the far side of a `gwssh` session, seated in
a pane.

## The clicks

The report was "mouse clicks aren't selecting anything over `gwssh`, but
the keyboard is fine". That phrasing is the whole diagnosis: nothing in
the host's mouse path knows or cares whether a client is local or remote,
so "remote" could not be the variable. What *was* different was the pane
— the local sessions worked because they had the root pane to themselves.

Only one mechanism kills every click while leaving keys working.
`InputState.setMouseButton` returns "unchanged" for a press while that
button is already down, and `Server.reportMouseButton` drops an unchanged
report. So a single lost release wedges that button down in the session
**permanently**: every later press is a no-op change, never broadcast, and
only releases get through — which salacommander (like everything else)
ignores.

The lost release came from `host/input.zig` gating press *and* release on
the same two conditions:

- `focusedCell` resolving the pointer inside the focused pane, and
- `skip_left`, the flag chrome sets when it has claimed the button.

Neither can be right for a release. Press inside the pane, drag into a
neighbour, a divider band, or onto a scrollbar that grabs the button
mid-drag, and the press went out while the release did not. In a window
with only the root pane this is unreachable — `cellFromPixel` clamps to
the grid, so `focusedCell` never refuses — which is exactly why it only
ever showed up in a pane.

### Decision: the release belongs to whoever got the press

`KeyInput.mouse_down` records which presses the host actually put on the
wire, and the release branch is then unconditional for anything in that
set. When the pointer has drifted out, the new `Server.focusedCellClamped`
pins the cell to the nearest one inside the pane rather than refusing.

This is the ordinary pointer-grab rule, and it is worth stating as an
invariant rather than a fix: **the host must never send a press it does
not later pair with a release.** Any new gate added to that loop has to
be applied at press time only. A press the host declines is also not
recorded, so its release is dropped too and the pair stays balanced.

### Also: the synthesized click carried the wrong frame

`handleMouseSelection` turns a press/release that did not become a drag
back into a synthetic click for the client. It reported the **window**
cell, straight off `cellFromPixel`, where every client numbers rows and
columns from its own pane's corner. Rows and columns off inside a pane,
and past the pane's far edge, outside the client's grid entirely. Now
routed through `focusedCell` like the rest.

## Ctrl+Shift+C → the selected paths

glyphwire-host swallows Ctrl+Shift+C as its own copy shortcut, so a
salacommander key binding could never have seen it. It already broadcasts
`copy_request` when its own selection is empty, which is how gw-shell
answers with its marked `gw-ls` paths — so salacommander answers that
instead of growing a binding.

That routing is better than a binding would have been, not just cheaper:
a drag-selection in the Ctrl+` shell panel still copies as *text*, because
the host only asks when it has nothing of its own, and while the panel is
up its embedded `gw-shell --embed` answers instead.

The answer is `Pane.selection` — marked entries, else the entry under the
cursor, the same set F5/F6 act on — formatted exactly as gw-shell formats
its own (`pathsLine`, space-separated, each path through
`wordsplit.quoteArgIfNeeded`). Deliberately byte-identical: both programs
answer the same chord, and a user pasting after `zip out.zip ` must not
get a different kind of argument list depending on which was on screen.

### Decision: `copy_request` is addressed, not fanned out

It was going to every `"clipboard"` subscriber. That is fine for `paste`,
which is data, but `copy_request` asks for a single clipboard *write* —
fanned out, every subscriber answers with `set_clipboard` and the last one
to arrive wins at random. Concretely: the shell sitting behind
salacommander overwriting the file paths with its prompt line.

So `copy_request` joined `key` / `text` / `mouse_button` / `mouse_move` in
`isFocusGatedEvent`. It is not raw input, but it is the direct answer to
one keystroke, and the same reasoning applies: it belongs to whatever the
user is looking at.

That required a small protocol-plumbing change. `copy_request` and `paste`
had been broadcast under the *stream* name they share (`"clipboard"`), so
`broadcast` could not tell them apart to gate one and not the other. They
now broadcast under their own names, and both are accepted as subscription
names alongside `clipboard`. Side effect worth knowing about:
salacommander had been subscribing to `"paste"`, which `setFromEvents`
never recognised — Ctrl+Shift+V there had been silently dead, and now
works.
