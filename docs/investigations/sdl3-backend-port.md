# Investigation: an SDL3 engine backend (`host_eng`), and what a pixzig port needs

Status: **built and running** on branch `host-eng-sdl3`. `zig build
host_sdl` produces `glyphwire-host-sdl`, an SDL3-windowed host that
accepts Japanese/CJK IME input the GLFW host never could. `zig build
host` still produces the GLFW host from the same `host/` tree; the two
are meant to coexist only until SDL3 proves out.

This document has two audiences:

1. **Whoever ports pixzig itself to SDL3.** §2-§6 are the mechanical
   record: every GLFW call this backend had to replace, the API
   mismatches that bit, and the structural simplifications SDL3 makes
   possible. `host_eng/` is a working reference implementation, but it
   is deliberately *not* a whole engine (§7) — read it as a scouting
   report, not a drop-in.
2. **glyphwire maintainers.** §8 is the list of things this branch did
   not fix.

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
  root.zig          PixzigEngine + PixzigAppRunner, SDL3 event pump
  platform_sdl.zig  Window: SDL_Window + GL context, clipboard, text-input area
  input.zig         Key/MouseButton enums, Keyboard/Mouse/InputManager (event-driven)
  window.zig        WindowState (window vs pixel size, HiDPI scale factor)
  viewport.zig      Viewport + ScalePolicy (behaviour-identical copy of pixzig's)
  pixzig_core.zig   Namespace shim: re-exports the vendored engine pieces
  libs/stb_truetype/   vendored C + Zig wrapper
  pixzig_src/       vendored, unmodified-in-behaviour copies of pixzig's
                    renderer/, resources.zig, common.zig, utils.zig,
                    system.zig, time.zig, web.zig, file_watcher.zig
```

Everything under `pixzig_src/` is a **verbatim copy** of pixzig's
`src/pixzig/` at the time of the port, except `resources.zig` (see §7).
Nothing in the renderer, font atlas, quad batching, texture or shader
code needed to change to move off GLFW — **the GLFW dependency was
entirely in windowing, input and the app runner.** That is the single
most useful finding here for a pixzig port: the blast radius is
`pixzig.zig` + `input/` + `window.zig`, and nothing else.

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

## 3. Structural wins for pixzig

These are simplifications a pixzig port should take, not just tolerate.

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

A pixzig port must keep all of this; `host_eng` dropped it because
glyphwire does not use it.

- **Audio** — `Engine.init` `@compileError`s if `audioOpts.enabled`.
  pixzig's `zaudio` is orthogonal to windowing and should just keep
  working alongside SDL; there is no reason to move to `SDL_AudioStream`.
- **Asset manifests** — same, `@compileError` on `manifestOpts`.
- **Gamepads** — `InputManager.init` silently ignores `numGamepads`.
  pixzig's `input/gamepad.zig` needs a real port to `SDL_Gamepad` +
  `SDL_EVENT_GAMEPAD_*`, which is a genuinely better API than GLFW's
  joystick polling.
- **Emscripten** — the GL ES branch in `init` was kept, but
  `PixzigAppRunner.run`'s `web.setMainLoop` export was dropped. SDL3 has
  its own emscripten story; this needs deciding, not copying.
- **`Camera2D`, `imgui.zig`, `console.zig`, flecs, `sequencer`,
  `a_star`, `collision`, `gamestate`, `tile/`** — untouched, and none of
  them touch GLFW, so they come along unchanged.
- **`Mouse` accessors** — pixzig exposes `lastPos`/`fbPos`/`lastRawPos`/
  `lastFbPos` over a two-buffer `MouseState`; `host_eng` keeps a single
  flat state with only what glyphwire calls.
- **Hot reload** — `pixzig_src/resources.zig` has its `FileWatcher` /
  `HotReload` / `checkHotReload` machinery **commented out** (see that
  file's header). This is a glyphwire decision, not an SDL one: the SDL
  app runner never called `checkHotReload`, so Debug builds were
  registering an inotify watch per font and icon that nothing ever
  drained. **pixzig must keep hot reload** — just make sure the runner
  actually calls it.
- **Tilemaps** — removed from the vendored `resources.zig`, which is what
  let the `xml` dependency go. pixzig obviously keeps them.

---

## 7. Suggested shape for the pixzig port

1. Add the `sdl` dependency; keep `zglfw` initially.
2. Introduce `src/pixzig/platform/` with `window.zig` (the `SDL_Window` +
   GL context wrapper) and move `WindowState` onto it. `Viewport`,
   `ScalePolicy` and `Camera2D` need no change at all.
3. Rewrite `input/keyboard.zig` + `input/mouse.zig` event-driven, with a
   pixzig-owned dense `Key`/`MouseButton` enum replacing `zglfw`'s.
   Decide keycode-vs-scancode (§4) — for a game engine, probably
   scancode, with the keycode available alongside for text-ish UI.
   Delete `getIndexForKey`, `setKeyboardTarget`, `setScrollTarget` and
   the module-level target pointers.
4. Port `input/gamepad.zig` to `SDL_Gamepad`.
5. Swap the `PixzigEngine.init` / `deinit` / `pollEvents` /
   `refreshWindowState` body per §2. `PixzigAppRunner.gameLoopCore` keeps
   its shape — poll, refresh, fixed-step update loop, render, swap —
   only the four calls inside change. **Keep the `checkHotReload` call.**
6. Add `InputOptions.textInput` and the three IME pieces from §4.
   `host_eng/input.zig` + `host/preedit.zig` are a working reference.
7. Only then delete `zglfw`.

`host_eng/` can be deleted from glyphwire once pixzig ships this, and
`host/app.zig`'s backend-selection shim
(`if (@hasDecl(pixzig.input, "Key")) pixzig.input else pixzig.glfw`)
with it.

---

## 8. Not fixed on this branch

Carried over from the review of the port. None of these block the host
running; several are one-liners someone should pick up.

**Behavioural**

- **IME key filtering during composition is unverified.** While a
  composition is active, key events are still forwarded to
  `glyphwire-shell`. SDL3 on Linux (ibus/fcitx) is believed to filter
  keys the IME consumes so they never surface as `SDL_EVENT_KEY_DOWN`;
  if that does not hold, pressing Space to convert kana or Enter to
  commit would *also* reach the shell and run the command. Needs ten
  seconds at a Japanese IME to settle. If it is broken, guard key
  forwarding in `host/input.zig` on `app.preedit.text(eng)` being
  non-empty — but keep Escape always forwarded, or a stuck preedit makes
  the terminal deaf to input.
- **No focus-loss resync** (§3). No `SDL_EVENT_WINDOW_FOCUS_LOST`
  handler, no reconcile against `SDL_GetKeyboardState`.
- **`Engine.setIcon` is a no-op stub** and `PixzigEngineOptions.defaultIcon`
  is never read, so `glyphwire-host-sdl` has no window icon.
  `SDL_CreateSurfaceFrom` + `SDL_SetWindowIcon` is a few lines.
- **`SDL_StartTextInput` failure is fatal** to `Engine.init`. It should
  warn and continue.
- **Mouse position starts at (0,0)** until the first motion event rather
  than being seeded from `SDL_GetMouseState`.
- **`SDLK_EXECUTE => .F25`** is an invented mapping; SDL has no F25.
  Should be `.unknown`.
- **Mouse button names diverge**: `x1`/`x2` here vs zglfw's
  `four`..`eight`. `left`/`right`/`middle` — the only three glyphwire
  looks up — match, so nothing breaks today, but it is an undeclared
  wire-name change of the same class as the F-key one.
- **`showCursor` is global**, not per-window (§2).

**Hygiene**

- `host_eng` is in neither `zig build package` nor the CI workflow, so
  nothing catches breakage. Deliberate while experimental; revisit when
  the SDL host becomes the default.
- `InputManager.init` silently drops `opts.numGamepads` instead of
  `@compileError`-ing like the audio and manifest guards do.
- Fields set but never read: `Mouse.fb_pos`, `WindowState.content_scale`,
  `Engine.scaleFactor`.
- `Engine.deinit` does not `SDL_GL_MakeCurrent(win, null)` before
  destroying the context.

---

## 9. References

- `host_eng/root.zig`, `host_eng/platform_sdl.zig`, `host_eng/input.zig`
  — the backend.
- `host/preedit.zig`, `host/render.zig` (`drawPreedit`),
  `host/caret.zig` (`screenCell`) — the IME overlay.
- `host_eng/pixzig_src/resources.zig` header — why hot reload and
  tilemaps are gone from the vendored copy.
- `host/app.zig` — the backend-selection shim keeping both hosts
  building from one tree.
- `src/key_encode.zig` — why the `Key` enum's field names are
  wire-visible.
- pixzig: `src/pixzig/pixzig.zig` (`PixzigEngine`, `PixzigAppRunner`),
  `src/pixzig/input/` (`keyboard.zig`, `mouse.zig`, `manager.zig`,
  `gamepad.zig`), `src/pixzig/window.zig`.
- [allyourcodebase/SDL](https://github.com/allyourcodebase/SDL) — the
  Zig build of SDL3 used here.
- [SDL3 text input docs](https://wiki.libsdl.org/SDL3/CategoryKeyboard)
  — `SDL_StartTextInput`, `SDL_SetTextInputArea`, `SDL_HINT_KEYCODE_OPTIONS`.
