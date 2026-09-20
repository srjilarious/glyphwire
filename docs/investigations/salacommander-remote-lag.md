# salacommander: why moving the pane cursor lagged over `--ssh`

Moving the cursor up and down in a salacommander pane felt sluggish in a
remote session, even on a local network, while everything else felt
fine. The obvious suspect was round trips: a handful of request/response
pairs per keystroke would turn one LAN round trip into five or ten, and
that is exactly what a laggy cursor feels like.

It was not round trips. It was one very large frame per keystroke.

## How it was measured

No window is needed. `glyphwire-server` runs headless, `glyphwire-probe`
injects keys over the wire, and `Client` counts what it writes:

```
glyphwire-server /tmp/gw.sock 160 50 &
GLYPHWIRE_SOCK=/tmp/gw.sock GLYPHWIRE_SALA_PROFILE=1 salacommander <dir> <dir> &
GLYPHWIRE_SOCK=/tmp/gw.sock glyphwire-probe key down tap
```

`Client.bytes_sent` / `frames_sent` (`src/client.zig`) are two adds per
flush, always on. `GLYPHWIRE_SALA_PROFILE` makes salacommander print
what each pane repaint cost between them. Together they answer the one
question that matters and that is invisible from outside an ssh pipe:
**frames or bytes?**

Test directory: 200 files, pane 160x50, 46 visible rows.

## What it cost

```
sala: pane 0 redraw rows=46 bytes=53717 frames=1
```

**One frame. 53.7 KB.** Per keystroke.

So the round-trip theory was wrong in both directions. There was no
round trip at all — a pane repaint is a single `batch` of notifications,
and `Batch.send` only waits for a reply when the batch contains a
request, which a repaint never does. The cost was the payload: a
`clear_area`, then a `write_text` per column per visible row, then a
`draw_icon` per row, ~250 JSON messages spliced into one frame.

On a local socket that is free, which is why this never showed up in
development. Through the `gw-agent` trunk inside ssh it is not: at
key-repeat rates, holding an arrow key is over a megabyte a second of
JSON, and the ssh channel window, not the network, is what the cursor
is waiting on.

The reason a whole pane was redrawn for a one-row change is simply that
`pane_dirty` was a `bool`. There was one repaint, and it drew everything.

## The fix

`pane_dirty` became a level (`PaneDirty`: `none` / `rows` / `full`), and
`Ui.dirtyFor` decides which one an action earns. A cursor move only
changes the row the cursor left and the row it landed on, so `rows`
draws those two, plus the footer (its summary names the entry under the
cursor).

A move that *scrolls* was the case that actually mattered — hold Down in
a long listing and every keystroke past the bottom edge scrolls — and
every row shifts, so there is no two-row diff. `move_content` already
existed for exactly this (`docs/api.md`; zoe's buffer pane uses it for
every sub-screen scroll): shift the list band on the host, then redraw
only the band the shift exposed. Worth checking the protocol before
assuming a primitive is missing.

The remaining fallbacks to a full repaint are deliberate: an open Alt+D
path field (the title row is a live text field), and a jump of a
screenful or more (`Home`, `End`, `PgUp`/`PgDn` past the edge), where no
row survives the shift and moving the content first would only add a
message to a full redraw.

## What it costs now

```
sala: pane 0 redraw rows=2 bytes=3165 frames=1
```

**53.7 KB → 3.2 KB, ~17x.** Over 60 consecutive Down presses through the
scroll boundary, 60 of 62 repaints took the cheap path; the two full
ones were the initial paint of each pane. `End` then `Home` correctly
fell back to full repaints.

Correctness was checked against the server's own grid rather than by
eye: after 60 Downs the layer's cells held the right contiguous run of
filenames with the footer naming the cursor's entry, and after 55 Ups
the same, so the incrementally-scrolled grid matches what a full repaint
would have produced.

## What is left on the table

~3.2 KB for two rows and a footer is around 230 bytes per JSON message,
which is the floor for this representation, not a salacommander problem.
Two rows cost more than they look because a cursor move changes each
row's *background*, so `writeRow` clears the row, which wipes the
foreground icon, which then has to be resent. A way to restyle a row's
background without disturbing its icons would roughly halve what is
left. Not worth a protocol addition on its own at 3 KB.
