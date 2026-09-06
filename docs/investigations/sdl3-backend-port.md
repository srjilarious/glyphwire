# Investigation: the SDL3 engine backend (`host_eng`)

Status: **landed and the only backend.** `zig build host` produces
`glyphwire-host`, an SDL3-windowed host that accepts Japanese/CJK IME
input the old GLFW host never could. The GLFW host is gone: pixzig
dropped zglfw in its own SDL3 port, so `host_eng/` is now glyphwire's
engine outright rather than an experiment running beside one.

`host_eng/` no longer refers to pixzig anywhere. The two are expected to
diverge — glyphwire needs a terminal's engine, not a game's — so the
vendored files were renamed off pixzig's names (`pixzig_core.zig` →
`core.zig`, `pixzig_src/` → `engine/`, `PixzigEngine*` → `Engine*`) and
the host imports the module as `host_eng`, not `pixzig`.

This document has two audiences:

1. **Whoever wants the mechanical GLFW → SDL3 record.** §2-§6 are it:
   every GLFW call this backend had to replace, the API mismatches that
   bit, and the structural simplifications SDL3 makes possible. pixzig's
   own port (its `src/pixzig/platform/` + `src/pixzig/input/`) followed
   this shape and reached the same conclusions independently.
2. **glyphwire maintainers.** §6 is what `host_eng` deliberately is not,
   §7 is why glyphwire kept it instead of switching to pixzig's port, and
   §8 is what the first SDL3 branch left unfixed and how each item was
   resolved.

---

## 1. What was built

`host_eng/` is a self-contained engine backend that `host/main.zig`
imports under the module name `pixzig`. It is a facade: it presents the
same surface `host/` already used from the real pixzig, so the entire
glyphwire host — ~3400 lines across `app`/`caret`/`input`/`render`/
`scroll`/`selection`/`window_sizing` — compiles unchanged against
either backend.

```
host_eng/
  root.zig          EngineType + AppRunner, SDL3 event pump
  platform_sdl.zig  Window: SDL_Window + GL context, clipboard, icon,
                    text-input area
  input.zig         Key/MouseButton enums, Keyboard/Mouse/InputManager
                    (event-driven)
  window.zig        WindowState (window vs pixel size, HiDPI scale factor)
  viewport.zig      Viewport + ScalePolicy
  core.zig          Namespace shim: re-exports the engine pieces below
  libs/stb_truetype/   vendored C + Zig wrapper
  engine/           backend-independent engine: renderer/, resources.zig,
                    common.zig, utils.zig, system.zig, time.zig, web.zig,
                    file_watcher.zig
```

Everything under `engine/` started as a copy of pixzig's
`src/pixzig/` at the time of the port, except `resources.zig` (see §6).
Nothing in the renderer, font atlas, quad batching, texture or shader
code needed to change to move off GLFW — **the GLFW dependency was
entirely in windowing, input and the app runner.** That was the single
most useful finding here, and it held for pixzig's own port too: the
blast radius is the engine root + `input/` + `window.zig`, nothing
else.

New dependencies (`build.zig.zon`):

```zig
.sdl = .{
    .url = "git+https://github.com/allyourcodebase/SDL.git#5d74fc4ba994547f7f2f77695c2f301298310d4d",
    .hash = "sdl-1.0.2+3.4.14-i4QD0SawqQBSVdA6eHm0lX16h_Jwf1vQXxI_lO0-09sY",
},
```

`sdl_dep.module("sdl3")` carries the static `libSDL3.a` with it, so a
consumer only needs `addImport("sdl3", ...)` — no separate
`linkLibrary`. `zopengl`, `zmath` and `zstbi` are unchanged from what
pixzig already used; only `zglfw` goes away.

---

## 2. GLFW → SDL3 call map

Everything pixzig's `PixzigEngine`/`PixzigAppRunner` calls, and its
replacement. Read the "notes" column carefully — the rows with notes are
where a naive substitution is wrong.

### Lifecycle and window

| pixzig / zglfw | SDL3 | Notes |
|---|---|---|
| `glfw.init()` / `glfw.terminate()` | `SDL_Init(SDL_INIT_VIDEO)` / `SDL_Quit()` | `SDL_INIT_EVENTS` is implied by `VIDEO` |
| `glfw.windowHint(.context_version_major, N)` | `SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, N)` | must precede `SDL_CreateWindow` |
| `.opengl_profile = .opengl_core_profile` | `SDL_GL_CONTEXT_PROFILE_MASK = SDL_GL_CONTEXT_PROFILE_CORE` | |
| `.opengl_forward_compat = true` | `SDL_GL_CONTEXT_FLAGS = SDL_GL_CONTEXT_FORWARD_COMPATIBLE_FLAG` | |
| `.doublebuffer = true` | `SDL_GL_DOUBLEBUFFER = 1` | |
| `.resizable = opts.resizable` | `SDL_WINDOW_RESIZABLE` window flag | a flag, not a hint |
| `glfw.createWindow(w, h, title, monitor, null)` | `SDL_CreateWindow(title, w, h, flags)` | fullscreen is the `SDL_WINDOW_FULLSCREEN` **flag**, not a monitor argument |
| — | `SDL_WINDOW_HIGH_PIXEL_DENSITY` | **new**; without it SDL gives a non-HiDPI framebuffer. Adding it makes `scale_factor` real — see §5 |
| `glfw.makeContextCurrent(win)` | `SDL_GL_CreateContext(win)` then `SDL_GL_MakeCurrent(win, ctx)` | two calls, and the context is a value to store |
| `glfw.getProcAddress` | `SDL_GL_GetProcAddress` | signatures differ; needs a `callconv(.c)` shim to hand to `zopengl.loadCoreProfile` |
| `glfw.swapInterval(0/1)` | `SDL_GL_SetSwapInterval(0/1)` | returns `bool`; can legitimately fail |
| `window.swapBuffers()` | `SDL_GL_SwapWindow(win)` | |
| `window.shouldClose()` | *no equivalent* | track a `close_requested` bool set from `SDL_EVENT_QUIT` and `SDL_EVENT_WINDOW_CLOSE_REQUESTED` |
| `glfw.getTime() * 1000` | `SDL_GetTicksNS() / 1_000_000` | ns, not seconds |
| `window.setSizeLimits(400, 400, -1, -1)` | `SDL_SetWindowMinimumSize(win, 400, 400)` | |
| `window.setSize(w, h)` | `SDL_SetWindowSize(win, w, h)` | both in **window** units, not pixels |
| `window.getSize()` | `SDL_GetWindowSize` | out-params, not a returned `[2]i32` |
| `window.getFramebufferSize()` | `SDL_GetWindowSizeInPixels` | |
| `window.getContentScale()` | `SDL_GetWindowDisplayScale` | **one** value, not per-axis; pixzig's `content_scale: Vec2F` gets the same number twice |
| `window.setIcon(&.{image})` | `SDL_CreateSurfaceFrom` + `SDL_SetWindowIcon` + `SDL_DestroySurface` | **not implemented here** — see §8 |
| `glfw.setInputMode(win, .cursor, .hidden)` | `SDL_ShowCursor()` / `SDL_HideCursor()` | **global**, not per-window. pixzig's per-window semantics are not reproducible directly |
| `window.setClipboardString(s)` | `SDL_SetClipboardText(s)` | |
| `window.getClipboardString()` | `SDL_GetClipboardText()` | **ownership differs.** GLFW returns a borrowed pointer valid until the next call; SDL returns a buffer the caller must `SDL_free`. `platform_sdl.zig` copies into a `clipboard_buf` owned by the `Window` so the borrowed-slice signature `host/selection.zig` expects still holds |

### Events

GLFW's callback registration is replaced wholesale by one
`SDL_PollEvent` loop in `Engine.pollEvents`:

| pixzig / zglfw | SDL3 |
|---|---|
| `setFramebufferSizeCallback` | `SDL_EVENT_WINDOW_RESIZED`, `SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED`, `SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED` → set `window_state.resized` |
| `setKeyCallback` (for the `mods` bitfield) | `event.key.mod` on `SDL_EVENT_KEY_DOWN`/`_UP` |
| `setCharCallback` (a `u32` codepoint) | `SDL_EVENT_TEXT_INPUT` — a **UTF-8 string**, not a codepoint |
| `setScrollCallback` | `SDL_EVENT_MOUSE_WHEEL` (honour `SDL_MOUSEWHEEL_FLIPPED`) |
| `window.getKey(k) == .press` polling | `SDL_EVENT_KEY_DOWN`/`_UP` → bitset |
| `window.getMouseButton(b)` polling | `SDL_EVENT_MOUSE_BUTTON_DOWN`/`_UP` |
| `window.getCursorPos()` | `SDL_EVENT_MOUSE_MOTION` (`event.motion.x/y`) |
| *nothing* | `SDL_EVENT_TEXT_EDITING` + `SDL_StartTextInput` + `SDL_SetTextInputArea` |

That last row is the whole reason for the port; §4 covers it.

---

## 3. Structural wins from the move

These are simplifications SDL3 makes possible, not just tolerable.

**The global callback-target pointers go away.** pixzig has
`var g_kb_target: ?*Keyboard` / `var g_scroll_mouse: ?*Mouse` plus
`setKeyboardTarget` / `setScrollTarget`, because GLFW's C callbacks have
nowhere to carry a `self`. SDL is polled, so the engine hands each event
straight to `InputManager.handleEvent(event)` and the module-level
mutable state — and the "only one Keyboard can receive events at a time"
limitation it imposed — disappears entirely.

**Key indices stop needing a linear scan.** pixzig's `getIndexForKey`
does an `inline for` over every `glfw.Key` field to map a key to a dense
bitset index, because GLFW's values are sparse (`-1`, `32..96`,
`256..348`). A backend-owned enum with default (dense) values makes the
index just `@intFromEnum`. `host_eng/input.zig` does this; it also drops
`comp.numEnumFields` in favour of `@typeInfo(...).@"enum".fields.len`.

**`text()` gets simpler.** pixzig buffers `[32]u21` codepoints from the
char callback and UTF-8-encodes them on read. SDL hands you UTF-8
already, so the buffer is just bytes. **But** truncation then has to
respect sequence boundaries — see `utf8Boundary` in
`host_eng/input.zig`. Cutting on a raw byte count puts half an encoded
codepoint on the wire, which for CJK (3 bytes/char) is not hypothetical.

**Watch out — polling self-healed, events do not.** pixzig re-reads
every key with `window.getKey()` each tick, so a missed or dropped edge
corrects itself within one frame. An event-driven bitset latches until
the matching event arrives. SDL3 does post key-ups on focus loss
(`SDL_SetKeyboardFocus(NULL)` → `SDL_ResetKeyboard()`), so this is
latent rather than active, but a port should still handle
`SDL_EVENT_WINDOW_FOCUS_LOST` by clearing the key/button state, or
reconcile against `SDL_GetKeyboardState` in `update()`. glyphwire
synthesizes typematic repeats from held keys, so one stuck key there
means a runaway repeat.

---

## 4. IME / text input — the actual payoff

GLFW gives you a char callback and nothing else. There is no way to see
an in-progress composition and no way to tell the OS where the caret is,
which is why the GLFW host could not usefully take Japanese input.

SDL3 gives three pieces, and **all three are needed** — implementing one
or two leaves the feature looking broken:

1. **`SDL_StartTextInput(window)`** — without it, no `SDL_EVENT_TEXT_INPUT`
   arrives at all. `host_eng` calls it in `Engine.init`. For a general
   engine this should be an `InputOptions` flag, not unconditional: a
   game usually does not want an IME bar armed, and on some platforms it
   changes on-screen-keyboard behaviour.
2. **`SDL_EVENT_TEXT_EDITING`** — the preedit: what the user is composing
   but has not committed. It never appears on the `TEXT_INPUT` stream.
   Without drawing it, the user types Japanese into an apparently dead
   window and only sees the result at commit. `Keyboard.preedit()` /
   `preeditCursorByte()` expose it; `host/preedit.zig` +
   `render.drawPreedit` draw it.
   - The composition is **not per-tick state**: it persists across frames
     until the IME replaces, commits or cancels it, so `finishTick` must
     leave it alone while it clears the typed-text buffer.
   - Clear it on `SDL_EVENT_TEXT_INPUT`. SDL does not reliably follow a
     commit with an empty editing event, and without this the committed
     text stays ghosted at the caret.
   - SDL reports the composition caret as a **codepoint** index, not a
     byte offset.
3. **`SDL_SetTextInputArea(window, rect, cursor)`** — where the IME puts
   its candidate window. Skip it and the candidate list sits at the
   window origin, over unrelated content. The rect is in **window
   coordinates, not pixels**, so a HiDPI-aware app has to divide its
   framebuffer-pixel caret rect back down by the scale factor.
   `host/preedit.zig:syncInputArea` does this, with a last-sent compare
   so it is one call per caret move rather than one per frame.

**Key identity changed, deliberately.** `mapKey` reads
`event.key.key` — SDL's *keycode*, resolved through the active OS
layout — where zglfw's `Key` is a *physical position*. On Dvorak or
AZERTY a key now reports the identity on its keycap rather than its
QWERTY position, which is what a terminal should do and what other
terminals do. SDL3's default `SDL_HINT_KEYCODE_OPTIONS`
(`"french_numbers,latin_letters"`) keeps Ctrl-chords on Latin letters
under a non-Latin layout such as Russian, so Ctrl+C still works in
Cyrillic. A **game** engine may well want `event.key.scancode`
(physical) instead, so WASD stays where the fingers are — this is a real
fork in the road for pixzig, not a detail.

**Enum field names are load-bearing in glyphwire.** `host/input.zig`
forwards `@tagName(key)` onto the wire and `src/key_encode.zig` matches
on those strings, so the SDL-side `Key` enum has to mirror zglfw's
names exactly. This branch shipped with lowercase `f1`..`f25` at first,
which silently made F1-F12 send nothing at all, because `key_encode`
matches `"F1"`. Anyone re-deriving the enum for pixzig should know these
names escape the engine.

---

## 5. HiDPI

`SDL_WINDOW_HIGH_PIXEL_DENSITY` is new relative to the GLFW path and
makes `framebuffer_size` genuinely differ from `window_size` on a 2x
display. Consequences worth knowing:

- `WindowState.scale_factor` (`framebuffer / window`) becomes the number
  that matters for coordinate math. `content_scale` (from
  `SDL_GetWindowDisplayScale`) can disagree with it under Wayland
  fractional scaling — prefer `scale_factor`.
- Anything handed **to** SDL in window units (`SDL_SetWindowSize`,
  `SDL_SetTextInputArea`) needs dividing back down.
  `host/window_sizing.zig:resizeWindowForCells` already did the right
  thing; `host/preedit.zig` had to learn it.
- `PixzigEngineInitOptions.windowSize` is in window units but glyphwire
  computes it from font *pixel* metrics, so on HiDPI the first frame
  opens roughly 2x too large and reflows on the next. Self-correcting,
  but visible, and it predates this branch.

---

## 6. What `host_eng` deliberately is not

Everything here is a game engine's job, not a terminal's. Each was
dropped because glyphwire does not use it; pixzig kept all of it through
its own port.

- **Audio** — `Engine.init` `@compileError`s if `audioOpts.enabled`.
  Audio is orthogonal to windowing: `zaudio` keeps working alongside SDL,
  with no reason to move to `SDL_AudioStream`.
- **Asset manifests** — same, `@compileError` on `manifestOpts`.
- **Gamepads** — `Engine.init` `@compileError`s on a non-zero
  `numGamepads`. `SDL_Gamepad` + `SDL_EVENT_GAMEPAD_*` is a genuinely
  better API than GLFW's joystick polling; glyphwire just has no use for
  either.
- **Emscripten** — the GL ES branch in `init` was kept (it now asks for
  the ES *profile* too, rather than requesting a contradictory GL 2.0
  core context), but `AppRunner.run`'s `web.setMainLoop` export was
  dropped. SDL3 has its own emscripten story; this needs deciding, not
  copying. Nothing builds this path today.
- **`Camera2D`, `imgui.zig`, `console.zig`, flecs, `sequencer`,
  `a_star`, `collision`, `gamestate`, `tile/`** — untouched, and none of
  them touch GLFW, so they come along unchanged.
- **`Mouse` accessors** — a game engine exposes `lastPos`/`fbPos`/
  `lastRawPos`/`lastFbPos` over a two-buffer `MouseState`; `host_eng`
  keeps a single flat state with only what glyphwire calls.
- **Hot reload** — `engine/resources.zig` has its `FileWatcher` /
  `HotReload` / `checkHotReload` machinery **commented out** (see that
  file's header). This is a glyphwire decision, not an SDL one: the SDL
  app runner never called `checkHotReload`, so Debug builds were
  registering an inotify watch per font and icon that nothing ever
  drained. If it ever comes back here, the thing worth watching is the
  user's config files under `~/.config/glyphwire/`, not engine assets.
- **Tilemaps** — removed from `resources.zig`, which is what let the
  `xml` dependency go.

---

## 7. Why `host_eng` stayed, and pixzig's own port

pixzig has since done the same port (its `src/pixzig/platform/window.zig`
and rewritten `src/pixzig/input/`), independently reaching the same
conclusions this document reached: a pixzig-owned dense `Key` enum, an
event-driven `Keyboard`/`Mouse`, `getIndexForKey` /
`setKeyboardTarget` / `setScrollTarget` and the module-level target
pointers deleted, `InputOptions.textInput` plus the three IME pieces from
§4, `SDL_Gamepad` for gamepads. Its `Key` and `MouseButton` field names
match `host_eng`'s exactly.

The one deliberate difference is keycode-vs-scancode (§4). pixzig tracks
**both**: `down`/`pressed` report the physical position (so WASD stays
under the same fingers on AZERTY) and `layoutDown`/`layoutPressed` report
the keycap. That is the right call for a game engine. glyphwire wants
only the keycap identity — a terminal should report what is printed on
the key, the way every other terminal does — so `host_eng` tracks that
one and nothing else.

So the §7 of the original draft ("`host_eng/` can be deleted once pixzig
ships this") is **not** what happened. `host_eng` is ~1300 lines plus a
renderer, against a full game engine carrying flecs, audio, tilemaps,
asset manifests and a scripting layer glyphwire will never call. The two
are expected to diverge further, not converge. Keeping the small one
in-tree costs a vendored renderer to maintain; taking the big one costs
a live path dependency on a separately-evolving engine plus a permanent
translation layer for every place a terminal disagrees with a game. The
small one won.

What that decision bought, mechanically:

- `host_eng/` names nothing after pixzig any more (`core.zig`,
  `engine/`, `EngineType`/`AppRunner`/`EngineOptions`), and the host
  imports it as `host_eng`.
- The `pixzig` path dependency is gone from `build.zig.zon`, and with it
  the sibling-checkout step in CI.
- `host/app.zig`'s backend-selection shim
  (`if (@hasDecl(pixzig.input, "Key")) pixzig.input else pixzig.glfw`)
  is gone, along with `Preedit.supported`, the `@hasDecl` guard that
  compiled the IME overlay away on the GLFW backend.

If pixzig's SDL3 work is ever worth pulling back in, the thing to copy is
a *file*, not a dependency.

---

## 8. What §8 of the original draft left unfixed

All of it is now closed. Recorded here with what each turned into,
because several were subtler than the one-liners they looked like.

**Behavioural**

- **IME key filtering during composition** — *verified, no code needed.*
  SDL3 on Linux does filter the keys the IME consumes: typing the
  hiragana for 日本語, choosing the kanji and confirming puts only the
  committed text on the wire. Space-to-convert and Enter-to-commit never
  surface as `SDL_EVENT_KEY_DOWN`, so `glyphwire-shell` never sees them
  as keystrokes and can't run the command line out from under a
  composition. The defensive "suppress key forwarding while composing"
  guard was therefore not added — it would have been dead code with a
  stuck-preedit failure mode of its own.
- **No focus-loss resync** — *fixed.* `Engine.pollEvents` handles
  `SDL_EVENT_WINDOW_FOCUS_LOST` by calling `InputManager.clear`. Both
  the current *and* previous tick's state are dropped: clearing only the
  current one would make the next tick report a `released` edge for every
  key that had been held, putting a key-up on the wire for a key-down no
  subscriber ever saw.
- **`Engine.setIcon` was a no-op stub** — *fixed.* It decodes through
  stbi and calls `Window.setIcon` (`SDL_CreateSurfaceFrom` +
  `SDL_SetWindowIcon`). `EngineOptions.defaultIcon` was **removed**
  rather than wired up: `host_eng` ships no assets of its own, so there
  was no default to point it at. A host that wants an icon calls
  `setIcon` with its own image.
- **`SDL_StartTextInput` failure was fatal** — *fixed.* It moved into
  `Window.create`, gated on the new `InputOptions.textInput` (default
  on), and warns instead of aborting: losing typed text is bad, losing
  the whole window over it is worse.
- **Mouse position started at (0, 0)** — *fixed.* `Engine.init` calls
  `InputManager.seedMousePos`, which reads `SDL_GetMouseState` once.
- **`SDLK_EXECUTE => .F25`** — *fixed by deleting `F25`.* SDL has no
  F25; neither does pixzig's enum. `SDLK_EXECUTE` now falls through to
  `.unknown`. Nothing in glyphwire referenced the name.
- **Mouse button names `x1`/`x2` vs zglfw's `four`..`eight`** — *settled
  as `x1`/`x2`.* pixzig independently made the same change, so there is
  no longer a second backend to disagree with, and `host/input.zig`
  forwards every field of the enum by name so this *is* wire-visible.
  Recorded in `docs/decisions.md`'s Input model.
- **`showCursor` is global**, not per-window (§2). Unchanged: SDL3 offers
  nothing else, and the engine only ever owns one window. Documented at
  the call site.

**Hygiene**

- **Neither packaged nor in CI** — *fixed.* `host_eng` is now what
  `glyphwire-host` is built from, so it is in `zig build package` and the
  Linux CI job by construction. The CI job also runs `zig build tests`
  now, and the test runner links `host_eng` (see below).
- **`InputManager.init` silently dropped `opts.numGamepads`** — *fixed.*
  `Engine.init` `@compileError`s on a non-zero count, alongside the
  existing audio and manifest guards.
- **Fields set but never read** — *fixed.* `Mouse.fb_pos`,
  `WindowState.content_scale` and `Engine.scaleFactor` are gone, and with
  `content_scale` went the `SDL_GetWindowDisplayScale` call and
  `Window.getDisplayScale` that fed it. Nothing wanted the display scale:
  every coordinate conversion here needs the real framebuffer/window
  ratio, which under Wayland fractional scaling is a different number.
- **`Engine.deinit` did not unbind the GL context** — *fixed.*
  `Window.destroy` calls `SDL_GL_MakeCurrent(handle, null)` before
  destroying it, and stops text input only if starting it succeeded.

**New: the backend has tests.** `tests/host_eng_tests.zig` (group tag
`host-eng`) covers the wire-visible `Key`/`MouseButton` names, the
absence of `F25`/`world_1`/`world_2`, the focus-loss clear including the
no-spurious-release-edge property, the IME preedit codepoint→byte caret
conversion, and the UTF-8-boundary cut in `Keyboard.text`. None of it
needs a window or a GL context; the cost is that the test binary links
libSDL3.a. `Keyboard.pushText` / `setPreedit` / `clearPreedit` were made
public to drive those paths without an SDL event queue — the same three
entry points pixzig's `Keyboard` exposes.

---

## 9. References

- `host_eng/root.zig`, `host_eng/platform_sdl.zig`, `host_eng/input.zig`
  — the backend.
- `host/preedit.zig`, `host/render.zig` (`drawPreedit`),
  `host/caret.zig` (`screenCell`) — the IME overlay.
- `host_eng/engine/resources.zig` header — why hot reload and tilemaps
  are gone from it.
- `tests/host_eng_tests.zig` — the backend's own tests (§8).
- `src/key_encode.zig` — why the `Key` enum's field names are
  wire-visible; `docs/decisions.md`'s Input model for the same, as a
  decision.
- pixzig's own SDL3 port, for comparison: `src/pixzig/platform/window.zig`,
  `src/pixzig/input/` (`keys.zig`, `keyboard.zig`, `mouse.zig`,
  `manager.zig`, `gamepad.zig`).
- [allyourcodebase/SDL](https://github.com/allyourcodebase/SDL) — the
  Zig build of SDL3 used here.
- [SDL3 text input docs](https://wiki.libsdl.org/SDL3/CategoryKeyboard)
  — `SDL_StartTextInput`, `SDL_SetTextInputArea`, `SDL_HINT_KEYCODE_OPTIONS`.
