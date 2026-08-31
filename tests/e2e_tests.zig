const std = @import("std");
const testz = @import("testz");
const glyphwire = @import("glyphwire");
const wire = glyphwire.wire;

/// Every test here that spawns the real `glyphwire-shell` binary with an
/// interactive prompt runs it through this first. The prompt now reads
/// `~/.config/glyphwire/shell.conf` and persists command history to
/// `~/.config/glyphwire/history` (see shell/main.zig) -- without this a
/// test that threads a real `$HOME` (e.g. the `~/` expansion test) would
/// write its typed commands into the developer's actual history file and
/// could pick up a stray real `shell.conf`. `GLYPHWIRE_NO_HISTORY`
/// disables history entirely; `GLYPHWIRE_CONFIG_DIR` points `shell.conf`
/// lookup at a throwaway path that won't exist.
fn sandboxShellConfig(env: *std.process.Environ.Map, alloc: std.mem.Allocator) !void {
    try env.put("GLYPHWIRE_NO_HISTORY", "1");
    const cfg_dir = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-e2e-cfg-{d}", .{std.Thread.getCurrentId()});
    defer alloc.free(cfg_dir);
    try env.put("GLYPHWIRE_CONFIG_DIR", cfg_dir);
}

/// Proves real inter-process discovery still works end to end: a separately
/// spawned OS process (the real `glyphwire-demo` binary, not a library call)
/// finds a socket purely via the `GLYPHWIRE_SOCK` env var and writes several
/// styled `write_text` runs that land correctly in the server's `Context`.
///
/// Superseded milestone-7's `shellSpawnsServerAndExecsClientTest`, which
/// spawned `glyphwire-shell` itself and waited for it to exit. That no
/// longer applies: glyphwire-shell is now the pixzig-windowed renderer (see
/// slice_plan.md, Milestone 8) and stays open rendering the grid rather than
/// exiting after launching a child, so it can't be driven headlessly from a
/// test. The `Server`/discovery-env-var mechanism this test cares about is
/// unchanged, so it's exercised directly against a library-bound `Server`
/// instead of going through the shell binary.
pub fn demoClientWritesStyledTextOverRealSocketTest(_: std.Io, alloc: std.mem.Allocator) !void {
    // testz hands every test `global_single_threaded`'s Io, which uses a
    // deliberately failing allocator (fine for the socket-only tests
    // elsewhere in this suite, since raw socket syscalls need no
    // allocation) -- but std.process.spawn needs a real arena internally
    // for argv/env blocks, so this test builds its own Io backed by a real
    // allocator instead of reusing the one testz passed in.
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ctx = try glyphwire.Context.init(alloc, 120, 50, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-e2e-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    // errdefer, not a plain trailing statement: an early `try` failure
    // below (child.wait, the exit-code assertion) must still join this
    // thread, or it's left running against this function's
    // about-to-be-invalid stack and per-test allocator once the function
    // returns -- corrupting a later, unrelated test's memory
    // nondeterministically. On the success path this is joined explicitly
    // instead (see below), deliberately before reading ctx directly, so
    // errdefer never fires there.
    const thread = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    errdefer thread.join();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const demo_path = try std.fmt.allocPrint(alloc, "{s}/zig-out/bin/glyphwire-demo", .{cwd_buf[0..cwd_len]});
    defer alloc.free(demo_path);

    var environ_map = std.process.Environ.Map.init(alloc);
    defer environ_map.deinit();
    try environ_map.put("GLYPHWIRE_SOCK", socket_path);

    var child = try std.process.spawn(io, .{
        .argv = &.{demo_path},
        .environ_map = &environ_map,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| try testz.expectEqual(code, 0),
        else => return error.TestUnexpectedResult,
    }

    thread.join();

    // "glyphwire" written at row 0, col 0 in cyan (see demo/main.zig).
    const c00 = ctx.root.cell(0, 0);
    try testz.expectEqualStr("g", c00.grapheme());
    try testz.expectEqual(c00.style.fg.r, 0);
    try testz.expectEqual(c00.style.fg.g, 255);
    try testz.expectEqual(c00.style.fg.b, 255);

    // "colored text over pixzig" at row 2, col 0 with a navy background.
    const c20 = ctx.root.cell(2, 0);
    try testz.expectEqualStr("c", c20.grapheme());
    switch (c20.style.bg) {
        .color => |bg| {
            try testz.expectEqual(bg.r, 40);
            try testz.expectEqual(bg.g, 40);
            try testz.expectEqual(bg.b, 90);
        },
        .image, .icon => return error.TestUnexpectedResult,
    }

    // A bg-only color swatch (space glyph, red background) at row 6, col 0.
    const c60 = ctx.root.cell(6, 0);
    try testz.expectEqualStr(" ", c60.grapheme());
    switch (c60.style.bg) {
        .color => |bg| {
            try testz.expectEqual(bg.r, 255);
            try testz.expectEqual(bg.g, 85);
            try testz.expectEqual(bg.b, 85);
        },
        .image, .icon => return error.TestUnexpectedResult,
    }
}

fn serveOne(server: *glyphwire.server.Server, alloc: std.mem.Allocator) void {
    server.acceptOne(alloc) catch |err| {
        std.debug.print("test server connection failed: {t}\n", .{err});
    };
}

/// Accepts connections forever instead of a fixed, easy-to-miscount
/// number of `acceptOne` calls -- see `shellExpandsTildeInCommandArgsTest`
/// for why getting that count wrong is a real, silent-hang-shaped bug.
/// Not joined by its caller: it only returns once the listener closes.
fn serveForeverThread(server: *glyphwire.server.Server, alloc: std.mem.Allocator) void {
    server.serveForever(alloc) catch |err| {
        std.log.err("test server stopped: {t}", .{err});
    };
}

/// Drives the real glyphwire-shell binary's interactive prompt (its
/// no-args mode) through a full real process: connects it to a
/// library-bound Server, reports simulated key presses over a second
/// connection (standing in for glyphwire-host, which would normally
/// capture and report them), and asserts the resulting grid content --
/// echo, Enter running the typed line as a command (see
/// `Prompt.runCommand`), and Backspace erasing a character in the prompt
/// that follows. Types a command name unlikely to exist so the failure
/// path is deterministic rather than depending on what's installed.
pub fn shellPromptEchoesTypedInputTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-shell-e2e-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    // Three connections need to be concurrently alive: the shell's own
    // Client (writing) and InputListener (subscribed) connections, held
    // for its whole run, plus this test's reporter connection -- see
    // server_tests.zig's broadcast test for why that needs one thread per
    // connection each blocked in its own acceptOne, not one thread
    // serving connections sequentially.
    //
    // Teardown is all `defer`, in the reverse of acquisition order
    // (threads joined last, since each thread's acceptOne only returns
    // once its own connection closes), so it runs correctly on *every*
    // exit path -- including an early `try`/`return error` from, say,
    // waitForCell timing out below. A previous version of this test used
    // plain statements at the end instead; when a wait timed out, that
    // skipped cleanup entirely and leaked threads still referencing this
    // function's about-to-be-invalid stack and per-test allocator,
    // corrupting a *later* test's memory nondeterministically (segfault/
    // hang symptoms that didn't point back to their real cause).
    const thread1 = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread1.join();
    const thread2 = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread2.join();
    const thread3 = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread3.join();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const shell_path = try std.fmt.allocPrint(alloc, "{s}/zig-out/bin/glyphwire-shell", .{cwd_buf[0..cwd_len]});
    defer alloc.free(shell_path);

    var shell_env = std.process.Environ.Map.init(alloc);
    defer shell_env.deinit();
    try shell_env.put("GLYPHWIRE_SOCK", socket_path);
    try sandboxShellConfig(&shell_env, alloc);

    // No args: triggers the interactive prompt rather than exec'ing into
    // a given command -- see shell/main.zig.
    var shell_child = try std.process.spawn(io, .{
        .argv = &.{shell_path},
        .environ_map = &shell_env,
    });
    // kill() itself blocks until the process actually terminates and
    // reaps it -- it's not a signal-and-return; calling wait() after it
    // too would be a double-wait (Child.kill's doc comment: "idempotent
    // and does nothing after wait returns", implying kill already is one).
    defer shell_child.kill(io);

    var reporter = try glyphwire.Client.connect(io, alloc, socket_path);
    defer reporter.deinit();

    // The prompt is now prefixed with the shell's cwd ("{cwd} > "), which
    // the spawned shell inherits from this test process -- `cwd_len`
    // (already computed above for `shell_path`) gives the column
    // assertions below without hardcoding the path this repo happens to
    // be checked out at.
    const arrow_col = cwd_len + 1;
    const text_col = cwd_len + 3;

    // Waits for the shell's initial prompt to land before typing, rather
    // than assuming a fixed startup delay is enough.
    try waitForCell(&reporter, 0, arrow_col, ">");

    // "nosuchcmd" resolves to nothing in zig-out/bin or $PATH, so Enter
    // reports the failure on the row below rather than crashing the
    // prompt -- see `Prompt.runCommand`. Characters go in as a `text`
    // notification (what the host sends after resolving the OS layout);
    // Enter is still a key event.
    try reporter.reportText("nosuchcmd");
    try reporter.reportKey("enter", true);
    try reporter.reportKey("enter", false);

    // The failed-command report lands on row 1 (always at col 0 -- it's
    // written before any prompt prefix); the next prompt starts on row 2
    // once the shell resyncs its cursor after that.
    try waitForCell(&reporter, 2, arrow_col, ">");

    // "z" after the backspace is an unambiguous completion marker: it can
    // only land where "e" was if the backspace actually ran first, so
    // waiting for it also proves the backspace worked, not just that
    // events arrived in order. (Waiting for "y" to land instead, tried
    // first, is wrong: "y" appears in the sequence *before*
    // "e"/"backspace" are even sent, so it doesn't wait for the
    // asynchronous hop through the real shell process at all -- it was
    // passing on stale state.)
    try reporter.reportText("bye");
    try reporter.reportKey("backspace", true);
    try reporter.reportKey("backspace", false);
    try reporter.reportText("z");

    try waitForCell(&reporter, 2, text_col + 2, "z");

    var snapshot = try reporter.getCells();
    defer snapshot.deinit();
    try testz.expectEqualStr(">", snapshot.cellAt(0, arrow_col).grapheme);
    try testz.expectEqualStr("n", snapshot.cellAt(0, text_col).grapheme);
    try testz.expectEqualStr("o", snapshot.cellAt(0, text_col + 1).grapheme);
    try testz.expectEqualStr("n", snapshot.cellAt(1, 0).grapheme); // "nosuchcmd: command not found (...)"
    try testz.expectEqualStr("o", snapshot.cellAt(1, 1).grapheme);
    try testz.expectEqualStr(":", snapshot.cellAt(1, 9).grapheme);
    try testz.expectEqualStr(">", snapshot.cellAt(2, arrow_col).grapheme);
    try testz.expectEqualStr("b", snapshot.cellAt(2, text_col).grapheme);
    try testz.expectEqualStr("y", snapshot.cellAt(2, text_col + 1).grapheme);
    try testz.expectEqualStr("z", snapshot.cellAt(2, text_col + 2).grapheme); // "e" was backspaced away, "z" took its place
}

/// Drives the real glyphwire-shell binary with a `shell.conf` that
/// configures a powerline `left_segments` prompt, and checks the
/// segment's text lands *on* its coloured background strip -- the
/// regression `emitOps` had where `writeSpaces` left the cursor at the
/// end of the strip so the text was written one strip-width to the
/// right, over blank default-background cells.
pub fn shellPowerlinePromptDrawsSegmentTextOnItsBackgroundTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-pl-e2e-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    const thread1 = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread1.join();
    const thread2 = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread2.join();
    const thread3 = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread3.join();

    // A throwaway config dir with a powerline shell.conf. One segment,
    // literal text "AB" (no `{cwd}` etc.), a distinctive blue bg.
    const cfg_dir = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-pl-e2e-cfg-{d}", .{std.Thread.getCurrentId()});
    defer alloc.free(cfg_dir);
    try std.Io.Dir.cwd().createDirPath(io, cfg_dir);
    defer std.Io.Dir.cwd().deleteTree(io, cfg_dir) catch {};
    const conf_path = try std.fs.path.join(alloc, &.{ cfg_dir, "shell.conf" });
    defer alloc.free(conf_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = conf_path,
        .data = "prompt { left_segments = { { \"AB\", fg = \"#ffffff\", bg = \"#1e88e5\" } }, lines = 1, input = \"> \" }\n",
    });

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const shell_path = try std.fmt.allocPrint(alloc, "{s}/zig-out/bin/glyphwire-shell", .{cwd_buf[0..cwd_len]});
    defer alloc.free(shell_path);

    var shell_env = std.process.Environ.Map.init(alloc);
    defer shell_env.deinit();
    try shell_env.put("GLYPHWIRE_SOCK", socket_path);
    try shell_env.put("GLYPHWIRE_NO_HISTORY", "1");
    try shell_env.put("GLYPHWIRE_CONFIG_DIR", cfg_dir);

    var shell_child = try std.process.spawn(io, .{
        .argv = &.{shell_path},
        .environ_map = &shell_env,
    });
    defer shell_child.kill(io);

    var reporter = try glyphwire.Client.connect(io, alloc, socket_path);
    defer reporter.deinit();

    // Segment strip is cols [0,2) on row 0; the input "> " follows it.
    try waitForCell(&reporter, 0, 0, "A");
    try waitForCell(&reporter, 0, 1, "B");

    var snapshot = try reporter.getCells();
    defer snapshot.deinit();

    // The text sits on the segment's blue background, not on blank cells.
    const a = snapshot.cellAt(0, 0);
    try testz.expectEqualStr("A", a.grapheme);
    try testz.expectTrue(a.bg != null);
    try testz.expectEqual(a.bg.?.r, 30);
    try testz.expectEqual(a.bg.?.g, 136);
    try testz.expectEqual(a.bg.?.b, 229);

    const b = snapshot.cellAt(0, 1);
    try testz.expectEqualStr("B", b.grapheme);
    try testz.expectTrue(b.bg != null);
    try testz.expectEqual(b.bg.?.b, 229);

    // And the input prompt follows the segment, not buried under shifted text.
    try testz.expectEqualStr(">", snapshot.cellAt(0, 2).grapheme);
}

/// Drives the real glyphwire-shell binary through a filename Tab
/// completion: types `ls sr` at the prompt and presses Tab, expecting the
/// only `sr*` entry in the shell's cwd (`src/`, this repo's source dir --
/// the test process runs from the repo root, same assumption
/// `shellPromptEchoesTypedInputTest` already makes for finding the shell
/// binary) to be filled in, with the trailing `/` a directory match
/// appends. Proves the whole path works over the real wire: key event ->
/// `Prompt.doComplete` -> directory scan -> `insert_cells`/`write_text`
/// back onto the grid.
pub fn shellTabCompletesUniqueFilenameTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-shell-tab-e2e-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    const thread1 = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread1.join();
    const thread2 = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread2.join();
    const thread3 = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread3.join();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const shell_path = try std.fmt.allocPrint(alloc, "{s}/zig-out/bin/glyphwire-shell", .{cwd_buf[0..cwd_len]});
    defer alloc.free(shell_path);

    var shell_env = std.process.Environ.Map.init(alloc);
    defer shell_env.deinit();
    try shell_env.put("GLYPHWIRE_SOCK", socket_path);
    try sandboxShellConfig(&shell_env, alloc);

    var shell_child = try std.process.spawn(io, .{
        .argv = &.{shell_path},
        .environ_map = &shell_env,
    });
    defer shell_child.kill(io);

    var reporter = try glyphwire.Client.connect(io, alloc, socket_path);
    defer reporter.deinit();

    const arrow_col = cwd_len + 1;
    const text_col = cwd_len + 3;

    try waitForCell(&reporter, 0, arrow_col, ">");

    try typeText(&reporter, "ls sr");
    // Wait for the last typed character to land before pressing Tab, so
    // the completion acts on the full word rather than a partial one.
    try waitForCell(&reporter, 0, text_col + 4, "r");

    try reporter.reportKey("tab", true);
    try reporter.reportKey("tab", false);

    // "ls sr" + Tab -> "ls src/": the "c" and "/" are what completion
    // added; waiting on the "/" proves the directory suffix ran.
    try waitForCell(&reporter, 0, text_col + 6, "/");

    var snapshot = try reporter.getCells();
    defer snapshot.deinit();
    try testz.expectEqualStr("s", snapshot.cellAt(0, text_col + 3).grapheme);
    try testz.expectEqualStr("r", snapshot.cellAt(0, text_col + 4).grapheme);
    try testz.expectEqualStr("c", snapshot.cellAt(0, text_col + 5).grapheme);
    try testz.expectEqualStr("/", snapshot.cellAt(0, text_col + 6).grapheme);
}

/// Drives the real glyphwire-shell binary through a `*` glob expansion:
/// types `echo *.zon` at the prompt and presses Enter. The shell's cwd
/// (this repo's root, same assumption the other shell e2e tests make)
/// contains exactly one `*.zon` file, `build.zig.zon`, so the expanded
/// argv is `echo build.zig.zon` and that filename is what lands on the
/// grid as the command's captured stdout. Proves the whole path:
/// `dispatchLine` -> `expandGlobs` -> directory scan -> spawn with the
/// substituted argument.
pub fn shellExpandsStarGlobInCommandArgsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-shell-glob-e2e-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    const thread1 = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread1.join();
    const thread2 = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread2.join();
    const thread3 = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread3.join();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const shell_path = try std.fmt.allocPrint(alloc, "{s}/zig-out/bin/glyphwire-shell", .{cwd_buf[0..cwd_len]});
    defer alloc.free(shell_path);

    var shell_env = std.process.Environ.Map.init(alloc);
    defer shell_env.deinit();
    try shell_env.put("GLYPHWIRE_SOCK", socket_path);
    try sandboxShellConfig(&shell_env, alloc);
    // `echo` lives on the system PATH, not under zig-out/bin -- forward
    // it explicitly, same as shellCapturesPlainCommandStdoutTest.
    const path_env = if (std.c.getenv("PATH")) |p| std.mem.sliceTo(p, 0) else "";
    const new_path = try std.fmt.allocPrint(alloc, "{s}/zig-out/bin:{s}", .{ cwd_buf[0..cwd_len], path_env });
    defer alloc.free(new_path);
    try shell_env.put("PATH", new_path);

    var shell_child = try std.process.spawn(io, .{
        .argv = &.{shell_path},
        .environ_map = &shell_env,
    });
    defer shell_child.kill(io);

    var reporter = try glyphwire.Client.connect(io, alloc, socket_path);
    defer reporter.deinit();

    const arrow_col = cwd_len + 1;
    try waitForCell(&reporter, 0, arrow_col, ">");

    try typeText(&reporter, "echo *.zon");
    try reporter.reportKey("enter", true);
    try reporter.reportKey("enter", false);

    // Expanded stdout is "build.zig.zon\n" on row 1 from col 0. The final
    // "n" landing proves the whole expanded name made it across.
    try waitForCell(&reporter, 1, 12, "n");

    var snapshot = try reporter.getCells();
    defer snapshot.deinit();
    for ("build.zig.zon", 0..) |expected_ch, i| {
        var expected_buf: [1]u8 = .{expected_ch};
        try testz.expectEqualStr(&expected_buf, snapshot.cellAt(1, i).grapheme);
    }
}

/// Types `text` at the shell prompt the way the host does: one `text`
/// notification carrying the already-layout-resolved characters. The
/// shell's prompt loop inserts from the `text` stream, so this is all it
/// takes -- no per-key `charFromKeyName` reverse table any more. Navigation
/// keys (Enter, Tab, arrows, Backspace) are still sent via `reportKey` by
/// the callers.
fn typeText(reporter: *glyphwire.Client, text: []const u8) !void {
    try reporter.reportText(text);
}

/// Proves `Prompt.runCommand` captures a plain (non-glyphwire-aware)
/// command's real stdout and mirrors it onto the grid via `write_text`,
/// the default behavior `pumpChildOutput` gives any spawned command that
/// never connects (`Client.connect` is what writes
/// `glyphwire.handshake_marker`) -- see shell/main.zig's top doc comment.
/// `/usr/bin/echo` is about as plain as a program gets: it
/// never touches `GLYPHWIRE_SOCK`, so this only passes if the shell
/// itself is putting its stdout on the grid, not `echo` doing it.
/// `shellExpandsTildeInCommandArgsTest`/`lsClientWritesEntriesOverRealSocketTest`
/// cover the opposite case (a real `glyphwire-ls` handshaking and drawing
/// structured output itself, not raw stdout bytes) implicitly, by still
/// passing under this same capture path.
pub fn shellCapturesPlainCommandStdoutTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-echo-e2e-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    // Three connections, same as shellPromptEchoesTypedInputTest: the
    // shell's own Client and InputListener, plus this test's reporter.
    // `echo` itself never connects -- it's a plain program, the whole
    // point of this test.
    const thread1 = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread1.join();
    const thread2 = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread2.join();
    const thread3 = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread3.join();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const shell_path = try std.fmt.allocPrint(alloc, "{s}/zig-out/bin/glyphwire-shell", .{cwd_buf[0..cwd_len]});
    defer alloc.free(shell_path);

    var shell_env = std.process.Environ.Map.init(alloc);
    defer shell_env.deinit();
    try shell_env.put("GLYPHWIRE_SOCK", socket_path);
    try sandboxShellConfig(&shell_env, alloc);
    // `/usr/bin/echo` isn't under `zig-out/bin`, so the real inherited
    // PATH has to be forwarded explicitly -- an explicit `environ_map`
    // replaces the child's whole environment rather than layering on top
    // of it, same reasoning as shellExpandsTildeInCommandArgsTest.
    const path_env = if (std.c.getenv("PATH")) |p| std.mem.sliceTo(p, 0) else "";
    const new_path = try std.fmt.allocPrint(alloc, "{s}/zig-out/bin:{s}", .{ cwd_buf[0..cwd_len], path_env });
    defer alloc.free(new_path);
    try shell_env.put("PATH", new_path);

    var shell_child = try std.process.spawn(io, .{
        .argv = &.{shell_path},
        .environ_map = &shell_env,
    });
    defer shell_child.kill(io);

    var reporter = try glyphwire.Client.connect(io, alloc, socket_path);
    defer reporter.deinit();

    const arrow_col = cwd_len + 1;
    try waitForCell(&reporter, 0, arrow_col, ">");

    try typeText(&reporter, "echo hello");
    try reporter.reportKey("enter", true);
    try reporter.reportKey("enter", false);

    // "echo hello"'s stdout ("hello\n") lands on row 1 starting at col 0,
    // same placement `runCommand`'s "command not found" report uses for
    // an unrecognized command -- both are written before any prompt
    // prefix. The whole chunk (trailing "\n" included) goes across as one
    // `write_text`; `Layer.writeText`'s own C0 handling turns the "\n"
    // into the row advance. Waiting for the final "o" (rather than the
    // first "h") proves the whole word made it across, not just that
    // capture started.
    try waitForCell(&reporter, 1, 4, "o");

    var snapshot = try reporter.getCells();
    defer snapshot.deinit();
    for ("hello", 0..) |expected_ch, i| {
        var expected_buf: [1]u8 = .{expected_ch};
        try testz.expectEqualStr(&expected_buf, snapshot.cellAt(1, i).grapheme);
    }

    // The next prompt lands two rows below the captured line: one for the
    // trailing newline `Layer.writeText` already advanced past while
    // mirroring the output, one more for `submitLine`'s own resync --
    // proving the shell picked its cursor back up correctly after a
    // captured command ran, not just that the capture itself worked.
    try waitForCell(&reporter, 3, arrow_col, ">");
}

/// After a command whose output scrolls the layer, the next powerline
/// prompt must settle on a real grid row and stay there -- not keep
/// creeping down one row per idle tick. `writePowerlinePrefix` used to
/// record its pre-scroll target row (`start.row + prompt_lines - 1`) as
/// `line_start_row`; when the input row landed past the bottom the layer
/// scrolled but `line_start_row` stayed one past the last valid row, so
/// every `renderInputLine` / idle `drawRightChain` re-`setCursor`'d off
/// the bottom and scrolled again.
pub fn shellPowerlinePromptStableAfterOutputScrollTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-plscroll-e2e-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);
    const thread1 = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread1.join();
    const thread2 = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread2.join();
    const thread3 = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    defer thread3.join();

    // Config: a 2-line powerline prompt with a right chain (so the idle
    // refresh path is active), plus a 40-line file to `cat`.
    const cfg_dir = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-plscroll-cfg-{d}", .{std.Thread.getCurrentId()});
    defer alloc.free(cfg_dir);
    try std.Io.Dir.cwd().createDirPath(io, cfg_dir);
    defer std.Io.Dir.cwd().deleteTree(io, cfg_dir) catch {};
    const conf_path = try std.fs.path.join(alloc, &.{ cfg_dir, "shell.conf" });
    defer alloc.free(conf_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = conf_path,
        .data =
        \\prompt {
        \\  left_segments = { { " L ", fg = "#fff", bg = "#3a3a3a" } },
        \\  right_segments = { { " R ", fg = "#fff", bg = "#5f87af" } },
        \\  lines = 2, input = "> ",
        \\}
        ,
    });
    var lines40: [400]u8 = undefined;
    var w: usize = 0;
    var n: usize = 0;
    while (n < 40) : (n += 1) {
        lines40[w] = 'x';
        lines40[w + 1] = '\n';
        w += 2;
    }
    const file_path = try std.fs.path.join(alloc, &.{ cfg_dir, "big.txt" });
    defer alloc.free(file_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = lines40[0..w] });

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const shell_path = try std.fmt.allocPrint(alloc, "{s}/zig-out/bin/glyphwire-shell", .{cwd_buf[0..cwd_len]});
    defer alloc.free(shell_path);

    var shell_env = std.process.Environ.Map.init(alloc);
    defer shell_env.deinit();
    try shell_env.put("GLYPHWIRE_SOCK", socket_path);
    try shell_env.put("GLYPHWIRE_NO_HISTORY", "1");
    try shell_env.put("GLYPHWIRE_CONFIG_DIR", cfg_dir);
    const path_env = if (std.c.getenv("PATH")) |p| std.mem.sliceTo(p, 0) else "";
    const new_path = try std.fmt.allocPrint(alloc, "{s}/zig-out/bin:{s}", .{ cwd_buf[0..cwd_len], path_env });
    defer alloc.free(new_path);
    try shell_env.put("PATH", new_path);

    var shell_child = try std.process.spawn(io, .{ .argv = &.{shell_path}, .environ_map = &shell_env });
    defer shell_child.kill(io);

    var reporter = try glyphwire.Client.connect(io, alloc, socket_path);
    defer reporter.deinit();

    // First prompt: the "> " input row of the 2-line prompt is row 1.
    try waitForCell(&reporter, 1, 0, ">");

    var cmd_buf: [256]u8 = undefined;
    try typeText(&reporter, try std.fmt.bufPrint(&cmd_buf, "cat {s}", .{file_path}));
    try reporter.reportKey("enter", true);
    try reporter.reportKey("enter", false);

    // Give `cat` time to run and the next prompt to be drawn. 40 lines of
    // output through a 24-row grid pushes the new prompt to the bottom.
    std.Io.sleep(io, .fromMilliseconds(700), .awake) catch {};

    // The new prompt's input row: a ">" at col 0 that the cursor sits just
    // after (col 2). The old prompt (row 1) has long since scrolled off.
    // Require the same row twice, ~120ms apart, so a mid-scroll snapshot
    // doesn't get mistaken for "settled".
    var settled_row: usize = 0;
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        const r1 = promptInputRow(&reporter) catch null;
        std.Io.sleep(reporter.io, .fromMilliseconds(120), .awake) catch {};
        const r2 = promptInputRow(&reporter) catch null;
        if (r1 != null and r2 != null and r1.? == r2.?) {
            settled_row = r1.?;
            break;
        }
    }
    try testz.expectTrue(settled_row > 1 and settled_row < 24);

    // Hold still across several idle ticks (500ms each). A stuck prompt
    // creeps down one row per tick; a fixed one doesn't move.
    std.Io.sleep(io, .fromMilliseconds(1700), .awake) catch {};
    const after = try promptInputRow(&reporter);
    try testz.expectEqual(after, settled_row);
}

/// The row of the 2-line powerline prompt's input line, or an error if
/// the cursor isn't currently on a ">"-at-col-0 input row (mid-redraw).
fn promptInputRow(reporter: *glyphwire.Client) !usize {
    const cur = try reporter.getCursor();
    if (cur.col != 2 or cur.row >= 24) return error.NotOnInputRow;
    var snap = try reporter.getCells();
    defer snap.deinit();
    if (!std.mem.eql(u8, snap.cellAt(cur.row, 0).grapheme, ">")) return error.NotOnInputRow;
    return cur.row;
}

/// Proves `Prompt.runCommand` actually expands a leading `~/` in a
/// command's arguments before spawning, the same way `doCd` already did
/// for `cd`'s target -- see shell/main.zig. Types `ls ~/<marker dir>` at
/// the real interactive prompt (`glyphwire-ls`, itself a real spawned
/// process, writes the result onto the grid) and confirms the marker
/// file inside a real directory under `$HOME` shows up -- proving `~/`
/// resolved to the actual home directory, not a literal `~` that
/// `openDir` would just fail to find.
pub fn shellExpandsTildeInCommandArgsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home_z = std.c.getenv("HOME") orelse return error.HomeNotSetInTestEnvironment;
    const home = std.mem.sliceTo(home_z, 0);
    const dir_name = try std.fmt.allocPrint(alloc, "glyphwire-tilde-test-{d}", .{std.Thread.getCurrentId()});
    defer alloc.free(dir_name);
    const dir_path = try std.fs.path.join(alloc, &.{ home, dir_name });
    defer alloc.free(dir_path);

    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    defer std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};
    var marker_dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer marker_dir.close(io);
    (try marker_dir.createFile(io, "marker.txt", .{})).close(io);

    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-tilde-e2e-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    // serveForever (not a fixed count of acceptOne threads, the pattern
    // the other e2e tests in this file use): this test's own reporter,
    // the shell's Client + InputListener, *and* glyphwire-ls's own Client
    // once the typed command spawns it all need servicing, and getting a
    // fixed accept-thread count wrong is exactly the kind of bug that
    // doesn't fail loudly -- it hangs. An earlier version of this test
    // hand-counted 3, then 4, connections and was wrong both times: ls's
    // connection would succeed at the socket layer (kernel-queued, within
    // the listen backlog) but sit unaccepted forever, so its first
    // request (`get_property` cursor, in `writeGrid`) blocked forever
    // waiting for a response that would never come -- which hung `ls`,
    // which hung `Prompt.runCommand`'s `child.wait()`, which hung the
    // shell. This test's own `waitForCell` still timed out on its own,
    // but `shell_child.kill()` afterward can't un-hang a *grandchild* it
    // doesn't own, so the shell was left orphaned and permanently
    // blocked. `serveForever` (same as `glyphwire-host` itself runs, see
    // host/main.zig's `serveForeverThread`) accepts connections as they
    // arrive instead of needing to know the count in advance. Not
    // joined: it only returns once the listener closes (`srv.deinit`),
    // and nothing needs its result before then.
    _ = try std.Thread.spawn(.{}, serveForeverThread, .{ &srv, alloc });

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const shell_path = try std.fmt.allocPrint(alloc, "{s}/zig-out/bin/glyphwire-shell", .{cwd_buf[0..cwd_len]});
    defer alloc.free(shell_path);

    var shell_env = std.process.Environ.Map.init(alloc);
    defer shell_env.deinit();
    try shell_env.put("GLYPHWIRE_SOCK", socket_path);
    try sandboxShellConfig(&shell_env, alloc);
    // Explicit environ_map replaces the child's whole environment (unlike
    // a plain inherited spawn), so HOME has to be threaded through by
    // hand for the shell's own expandTilde to resolve against the same
    // $HOME this test just created the marker directory under.
    try shell_env.put("HOME", home);
    // Same dev-mode PATH convenience shell/main.zig's own
    // prependZigOutBinToPath gives itself, so plain "ls" (typed below)
    // resolves to the real glyphwire-ls binary this test just built.
    const path_env = if (std.c.getenv("PATH")) |p| std.mem.sliceTo(p, 0) else "";
    const new_path = try std.fmt.allocPrint(alloc, "{s}/zig-out/bin:{s}", .{ cwd_buf[0..cwd_len], path_env });
    defer alloc.free(new_path);
    try shell_env.put("PATH", new_path);

    var shell_child = try std.process.spawn(io, .{
        .argv = &.{shell_path},
        .environ_map = &shell_env,
    });
    defer shell_child.kill(io);

    var reporter = try glyphwire.Client.connect(io, alloc, socket_path);
    defer reporter.deinit();

    const arrow_col = cwd_len + 1;
    try waitForCell(&reporter, 0, arrow_col, ">");

    var cmd_buf: [128]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, "ls ~/{s}", .{dir_name});
    try typeText(&reporter, cmd);
    try reporter.reportKey("enter", true);
    try reporter.reportKey("enter", false);

    // If ~/ expanded correctly, glyphwire-ls lists the marker directory
    // and "marker.txt" lands on row 2 starting at ls/main.zig's
    // icon_col_width -- 5 at this ctx's 12x12 cell metrics with the
    // default 48px icons, see lsClientWritesEntriesOverRealSocketTest's
    // comment for the formula (row 2, not 1: `writeGrid` leaves a blank
    // leading row). If it didn't (a literal "~" directory that doesn't
    // exist), the listing is empty and the *next prompt* shows up on row 1
    // instead -- so waiting specifically for "marker.txt"'s first letter
    // here fails (times out) rather than false-passing on an empty listing.
    try waitForCell(&reporter, 2, 5, "m");

    var snapshot = try reporter.getCells();
    defer snapshot.deinit();
    for ("marker.txt", 0..) |expected_ch, i| {
        var expected_buf: [1]u8 = .{expected_ch};
        try testz.expectEqualStr(&expected_buf, snapshot.cellAt(2, 5 + i).grapheme);
    }

    // glyphwire-ls handshakes by writing only `handshake_marker` to its
    // stdout and then drawing over its own wire connection -- it never
    // produces more stdout for `pumpChildOutput`'s read loop to wake on,
    // so the marker sits unresolved until EOF. `pumpChildOutput` must
    // recognize it there; otherwise its bytes get mirrored onto the grid
    // as the literal text "glyphwire-handshake-v1". Scan the first few
    // rows to prove none did.
    var row: usize = 0;
    while (row < 4) : (row += 1) {
        var col: usize = 0;
        var line_buf: [80]u8 = undefined;
        var line_len: usize = 0;
        while (col < 40) : (col += 1) {
            const g = snapshot.cellAt(row, col).grapheme;
            if (g.len == 1 and line_len < line_buf.len) {
                line_buf[line_len] = g[0];
                line_len += 1;
            }
        }
        if (std.mem.indexOf(u8, line_buf[0..line_len], "glyphwire-handshake") != null) {
            return error.HandshakeMarkerLeakedToGrid;
        }
    }
}

/// Polls `get_property(cursor)` until its row matches `want_row` -- the
/// same "poll real state, don't guess timing" philosophy `waitForCell`
/// already uses, needed here because `browseUp`'s effect (moving the
/// server-side cursor) isn't otherwise observable through `get_cells`.
fn waitForCursorRow(client: *glyphwire.Client, want_row: usize) !void {
    var attempts: usize = 0;
    while (attempts < 1000) : (attempts += 1) {
        const cur = try client.getCursor();
        if (cur.row == want_row) return;
        std.Io.sleep(client.io, .fromMilliseconds(10), .awake) catch {};
    }
    return error.TimedOutWaitingForCursorRow;
}

/// Same as `waitForCursorRow`, for the column.
fn waitForCursorCol(client: *glyphwire.Client, want_col: usize) !void {
    var attempts: usize = 0;
    while (attempts < 1000) : (attempts += 1) {
        const cur = try client.getCursor();
        if (cur.col == want_col) return;
        std.Io.sleep(client.io, .fromMilliseconds(10), .awake) catch {};
    }
    return error.TimedOutWaitingForCursorCol;
}

/// End-to-end proof of the browse-mode auto-cd feature (glyphwire-shell's
/// `Prompt.browseUp`/`browseEnter`, driven by plain Up/Enter): types
/// `ls <dir>` where `<dir>` contains one subdirectory, waits for the
/// listing and the next prompt, presses Up enough times to land the browse
/// cursor back on the subdirectory's row (deterministic here -- a single
/// entry's icon lands at row 2, per `lsClientWritesEntriesOverRealSocketTest`'s
/// row-math comment (`writeGrid` leaves a blank leading row), and the next
/// prompt five rows below that, at row 7, since `writeGrid` leaves the
/// cursor at `entry_row + block_rows` (4 for the default 48px icon at this
/// test's 12px cells) and `submitLine` adds one more), then presses Enter
/// and confirms the *next* prompt's cwd
/// echo shows the subdirectory -- i.e. a real `cd` actually ran, not just
/// that browsing moved a cursor around.
///
/// Shares `shellExpandsTildeInCommandArgsTest`'s known flakiness under
/// load: it also spawns a real `glyphwire-shell` that spawns a real
/// `glyphwire-ls` grandchild, so `waitForCell`/`waitForCursorRow`/
/// `waitForCursorCol`'s polling budgets can occasionally not be enough --
/// intermittent, not a logic bug (feature confirmed working manually
/// against a real interactive session), but a real one; don't chase it as
/// a regression.
pub fn shellBrowseUpAndEnterAutoCdsIntoDirectoryTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dir_name = try std.fmt.allocPrint(alloc, "glyphwire-browse-cd-test-{d}", .{std.Thread.getCurrentId()});
    defer alloc.free(dir_name);
    const dir_path = try std.fs.path.join(alloc, &.{ "/tmp", dir_name });
    defer alloc.free(dir_path);

    try std.Io.Dir.cwd().createDirPath(io, dir_path);
    defer std.Io.Dir.cwd().deleteTree(io, dir_path) catch {};
    var parent_dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer parent_dir.close(io);
    try parent_dir.createDir(io, "target", .default_dir);

    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-browse-cd-e2e-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);
    // serveForever, not a fixed accept-thread count -- see
    // shellExpandsTildeInCommandArgsTest's comment on why: this test also
    // spawns glyphwire-ls as a grandchild via the typed `ls` command.
    _ = try std.Thread.spawn(.{}, serveForeverThread, .{ &srv, alloc });

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const shell_path = try std.fmt.allocPrint(alloc, "{s}/zig-out/bin/glyphwire-shell", .{cwd_buf[0..cwd_len]});
    defer alloc.free(shell_path);

    var shell_env = std.process.Environ.Map.init(alloc);
    defer shell_env.deinit();
    try shell_env.put("GLYPHWIRE_SOCK", socket_path);
    try sandboxShellConfig(&shell_env, alloc);
    const path_env = if (std.c.getenv("PATH")) |p| std.mem.sliceTo(p, 0) else "";
    const new_path = try std.fmt.allocPrint(alloc, "{s}/zig-out/bin:{s}", .{ cwd_buf[0..cwd_len], path_env });
    defer alloc.free(new_path);
    try shell_env.put("PATH", new_path);

    var shell_child = try std.process.spawn(io, .{
        .argv = &.{shell_path},
        .environ_map = &shell_env,
    });
    defer shell_child.kill(io);

    var reporter = try glyphwire.Client.connect(io, alloc, socket_path);
    defer reporter.deinit();

    const arrow_col = cwd_len + 1;
    try waitForCell(&reporter, 0, arrow_col, ">");

    var cmd_buf: [128]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, "ls {s}", .{dir_path});
    try typeText(&reporter, cmd);
    try reporter.reportKey("enter", true);
    try reporter.reportKey("enter", false);

    // "target"'s row/col per lsClientWritesEntriesOverRealSocketTest's
    // formula (12x12 cell metrics, default 48px icons: one entry -> row 2
    // after `writeGrid`'s blank leading row, name at icon_col_width == 5).
    try waitForCell(&reporter, 2, 5, "t");
    // The next prompt: entry_row (2) + 4 (writeGrid's post-entry advance,
    // block_rows for a 48px icon at 12px cells) + 1 (submitLine's own
    // advance) == row 7, same cwd (nothing's cd'd yet) so the same arrow_col.
    try waitForCell(&reporter, 7, arrow_col, ">");

    // Five Up presses walk the browse cursor from the prompt row (7) back
    // up to the entry's row (2).
    var row_presses: usize = 0;
    while (row_presses < 5) : (row_presses += 1) {
        try reporter.reportKey("up", true);
        try reporter.reportKey("up", false);
    }
    try waitForCursorRow(&reporter, 2);

    // Up only ever changes the browse cursor's *row* -- its column starts
    // (and, until Left/Right move it, stays) wherever the real cursor was
    // on the prompt line, i.e. right after the "{cwd} > " prefix
    // (`cwd_len + 3`: space, '>', space), nowhere near "target"'s tagged
    // cells (icon at col 0, name at icon_col_width == 5). Left has to walk
    // it back over there before Enter means anything.
    const line_start_col = cwd_len + 3;
    const icon_col_width = 5;
    var col_presses: usize = 0;
    while (col_presses < line_start_col - icon_col_width) : (col_presses += 1) {
        try reporter.reportKey("left", true);
        try reporter.reportKey("left", false);
    }
    try waitForCursorCol(&reporter, icon_col_width);

    try reporter.reportKey("enter", true);
    try reporter.reportKey("enter", false);

    // A real `cd` ran: the next prompt's cwd echo includes "target". Row
    // 9 -- `doCd` writes nothing to the grid on success, so `submitLine`'s
    // post-command `getCursor()` still reads back the row it set for
    // itself (entry_row(2) + block_rows(4), from browseEnter's synthesized
    // "cd ..." line, then +1 again) before the final +1 for the new prompt.
    var found = false;
    var attempts: usize = 0;
    while (attempts < 1000 and !found) : (attempts += 1) {
        var snapshot = try reporter.getCells();
        defer snapshot.deinit();
        var col: usize = 0;
        while (col + 6 <= snapshot.cols()) : (col += 1) {
            var matched = true;
            for ("target", 0..) |expected_ch, i| {
                if (snapshot.cellAt(9, col + i).grapheme.len != 1 or snapshot.cellAt(9, col + i).grapheme[0] != expected_ch) {
                    matched = false;
                    break;
                }
            }
            if (matched) {
                found = true;
                break;
            }
        }
        if (!found) std.Io.sleep(reporter.io, .fromMilliseconds(10), .awake) catch {};
    }
    try testz.expectTrue(found);
}

/// Proves the real `glyphwire-ls` binary (see ls/main.zig, the first
/// "ported real program" client, built on lsz's directory-scanning logic)
/// connects, lists a directory, and writes the entries onto the grid --
/// the same discovery/write path `demoClientWritesStyledTextOverRealSocketTest`
/// exercises for the styled-text demo, but for the client meant to be
/// launched from glyphwire-shell's prompt. Uses a throwaway temp directory
/// with known contents rather than this repo's own tree, so the assertions
/// don't depend on glyphwire's directory layout.
pub fn lsClientWritesEntriesOverRealSocketTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const tmp_name = try std.fmt.allocPrint(alloc, "glyphwire-ls-e2e-test-{d}", .{std.Thread.getCurrentId()});
    defer alloc.free(tmp_name);
    try std.Io.Dir.cwd().createDirPath(io, tmp_name);
    defer std.Io.Dir.cwd().deleteTree(io, tmp_name) catch {};
    var tmp_dir = try std.Io.Dir.cwd().openDir(io, tmp_name, .{ .iterate = true });
    defer tmp_dir.close(io);

    // Sorted by name: "afile.txt" < "bdir" < "clink" < ".hidden" is
    // excluded by default (no -a), proving that filter still applies.
    (try tmp_dir.createFile(io, "afile.txt", .{})).close(io);
    try tmp_dir.createDir(io, "bdir", .default_dir);
    try tmp_dir.symLink(io, "afile.txt", "clink", .{});
    (try tmp_dir.createFile(io, ".hidden", .{})).close(io);

    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-ls-e2e-test-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    const thread = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    errdefer thread.join();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const ls_path = try std.fmt.allocPrint(alloc, "{s}/zig-out/bin/ls", .{cwd_buf[0..cwd_len]});
    defer alloc.free(ls_path);

    var environ_map = std.process.Environ.Map.init(alloc);
    defer environ_map.deinit();
    try environ_map.put("GLYPHWIRE_SOCK", socket_path);

    var child = try std.process.spawn(io, .{
        .argv = &.{ ls_path, tmp_name },
        .environ_map = &environ_map,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| try testz.expectEqual(code, 0),
        else => return error.TestUnexpectedResult,
    }

    thread.join();

    // `writeGrid` now packs entries into columns across the layer width
    // (column-major, like `ls -C`) instead of one per row. Each entry's
    // block is `icon_cols + name_cols + gap` wide: the `.natural` icon
    // reserves columns for `large_icon_px` (48 by default) at this ctx's
    // 12x12 cell metrics -- `(48 + 12 - 1) / 12 + 1 == 5`; the name area
    // is the longest display string clamped to [8, 40] ("clink -> afile.txt"
    // == 18); the gap is 2 -- so `block_cols == 25`. An 80-wide layer fits
    // 3 such blocks, and with only 3 entries that's one row of three
    // columns at base columns 0, 25, 50; names start `icon_cols == 5`
    // past each. `writeGrid` leaves a blank leading row for breathing
    // room, so the band lands on row 1, not row 0.
    try testz.expectEqualStr("a", ctx.root.cell(1, 5).grapheme()); // "afile.txt"
    try testz.expectEqualStr("b", ctx.root.cell(1, 30).grapheme());
    try testz.expectEqualStr("/", ctx.root.cell(1, 34).grapheme()); // "bdir/"
    try testz.expectEqualStr("c", ctx.root.cell(1, 55).grapheme());
    try testz.expectEqualStr(">", ctx.root.cell(1, 62).grapheme()); // "clink -> afile.txt"
}

/// Proves the multi-operand + file-operand path (`classifyAndList` in
/// ls/main.zig): a non-directory operand and a directory operand
/// together produce the coreutils layout -- the loose file first with no
/// header, then the directory under an `<operand>:` header, on a later
/// row. Uses the real binary like `lsClientWritesEntriesOverRealSocketTest`.
pub fn lsMultipleOperandsGroupsLooseFilesThenDirsTest(_: std.Io, alloc: std.mem.Allocator) !void {
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const tmp_name = try std.fmt.allocPrint(alloc, "glyphwire-ls-multi-e2e-{d}", .{std.Thread.getCurrentId()});
    defer alloc.free(tmp_name);
    try std.Io.Dir.cwd().createDirPath(io, tmp_name);
    defer std.Io.Dir.cwd().deleteTree(io, tmp_name) catch {};
    var tmp_dir = try std.Io.Dir.cwd().openDir(io, tmp_name, .{ .iterate = true });
    defer tmp_dir.close(io);

    (try tmp_dir.createFile(io, "zeta.txt", .{})).close(io);
    try tmp_dir.createDir(io, "sub", .default_dir);
    var sub_dir = try tmp_dir.openDir(io, "sub", .{});
    defer sub_dir.close(io);
    (try sub_dir.createFile(io, "inner.txt", .{})).close(io);

    var ctx = try glyphwire.Context.init(alloc, 80, 24, 0);
    defer ctx.deinit();

    const socket_path = try std.fmt.allocPrint(alloc, "/tmp/glyphwire-ls-multi-e2e-{d}.sock", .{std.Thread.getCurrentId()});
    defer alloc.free(socket_path);
    defer std.Io.Dir.deleteFileAbsolute(io, socket_path) catch {};

    var srv = try glyphwire.server.Server.bind(io, &ctx, socket_path);
    defer srv.deinit(alloc);

    const thread = try std.Thread.spawn(.{}, serveOne, .{ &srv, alloc });
    errdefer thread.join();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const ls_path = try std.fmt.allocPrint(alloc, "{s}/zig-out/bin/ls", .{cwd_buf[0..cwd_len]});
    defer alloc.free(ls_path);

    const file_operand = try std.fmt.allocPrint(alloc, "{s}/zeta.txt", .{tmp_name});
    defer alloc.free(file_operand);
    const dir_operand = try std.fmt.allocPrint(alloc, "{s}/sub", .{tmp_name});
    defer alloc.free(dir_operand);

    var environ_map = std.process.Environ.Map.init(alloc);
    defer environ_map.deinit();
    try environ_map.put("GLYPHWIRE_SOCK", socket_path);

    var child = try std.process.spawn(io, .{
        .argv = &.{ ls_path, file_operand, dir_operand },
        .environ_map = &environ_map,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| try testz.expectEqual(code, 0),
        else => return error.TestUnexpectedResult,
    }
    thread.join();

    // The loose file block is first, headerless. `writeGrid` leaves a
    // blank leading row, so it lands on row 1: its name is the operand
    // string as typed ("<tmp>/zeta.txt"), drawn after the icon reserve
    // (col 5 at 48px icons / 12px cells). `tmp_name` starts with 'g'.
    try testz.expectEqualStr("g", ctx.root.cell(1, 5).grapheme());

    // Find the row where "inner.txt" was written (col 5 onward). Two rows
    // above it is the "<tmp>/sub:" header (`writeGrid`'s blank leading row
    // sits between the header and the band) -- starts with 'g', ends in
    // ':'.
    var inner_row: ?usize = null;
    var r: usize = 1;
    while (r < 24) : (r += 1) {
        if (ctx.root.cell(r, 5).grapheme().len == 1 and ctx.root.cell(r, 5).grapheme()[0] == 'i' and
            ctx.root.cell(r, 6).grapheme().len == 1 and ctx.root.cell(r, 6).grapheme()[0] == 'n')
        {
            inner_row = r;
            break;
        }
    }
    try testz.expectTrue(inner_row != null);
    const header_row = inner_row.? - 2;
    try testz.expectEqualStr("g", ctx.root.cell(header_row, 0).grapheme());
    var saw_colon = false;
    var c: usize = 0;
    while (c < 60) : (c += 1) {
        const g = ctx.root.cell(header_row, c).grapheme();
        if (g.len == 1 and g[0] == ':') saw_colon = true;
    }
    try testz.expectTrue(saw_colon);
}

/// Polls get_cells (briefly) until `cell(row,col)`'s grapheme matches, so
/// this test doesn't race the shell's own asynchronous processing with a
/// guessed fixed delay. 1000 attempts (~10s worst case) rather than a
/// tighter bound: `shellExpandsTildeInCommandArgsTest` waits on a second
/// spawned process (glyphwire-ls) on top of the shell itself, and under
/// load a smaller budget wasn't consistently enough for that extra
/// process-spawn hop -- intermittent, not a logic bug, but a real one (it
/// read as a hang until bisected with a standalone repro outside testz's
/// output capturing).
fn waitForCell(client: *glyphwire.Client, row: usize, col: usize, expected: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 1000) : (attempts += 1) {
        var snapshot = try client.getCells();
        defer snapshot.deinit();
        if (std.mem.eql(u8, snapshot.cellAt(row, col).grapheme, expected)) return;
        std.Io.sleep(client.io, .fromMilliseconds(10), .awake) catch {};
    }
    return error.TimedOutWaitingForCell;
}
