const std = @import("std");
const testz = @import("testz");
const glyphwire = @import("glyphwire");
const wire = glyphwire.wire;

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
        .image => return error.TestUnexpectedResult,
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
        .image => return error.TestUnexpectedResult,
    }
}

fn serveOne(server: *glyphwire.server.Server, alloc: std.mem.Allocator) void {
    server.acceptOne(alloc) catch |err| {
        std.debug.print("test server connection failed: {t}\n", .{err});
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
    // prompt -- see `Prompt.runCommand`.
    const cmd_keys = [_][]const u8{ "n", "o", "s", "u", "c", "h", "c", "m", "d", "enter" };
    for (cmd_keys) |k| {
        try reporter.reportKey(k, true);
        try reporter.reportKey(k, false);
    }

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
    const edit_keys = [_][]const u8{ "b", "y", "e", "backspace", "z" };
    for (edit_keys) |k| {
        try reporter.reportKey(k, true);
        try reporter.reportKey(k, false);
    }

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

    try testz.expectEqualStr("a", ctx.root.cell(0, 0).grapheme());
    try testz.expectEqualStr("b", ctx.root.cell(1, 0).grapheme());
    try testz.expectEqualStr("/", ctx.root.cell(1, 4).grapheme()); // "bdir/"
    try testz.expectEqualStr("c", ctx.root.cell(2, 0).grapheme());
    try testz.expectEqualStr(">", ctx.root.cell(2, 7).grapheme()); // "clink -> afile.txt"
}

/// Polls get_cells (briefly) until `cell(row,col)`'s grapheme matches, so
/// this test doesn't race the shell's own asynchronous processing with a
/// guessed fixed delay.
fn waitForCell(client: *glyphwire.Client, row: usize, col: usize, expected: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        var snapshot = try client.getCells();
        defer snapshot.deinit();
        if (std.mem.eql(u8, snapshot.cellAt(row, col).grapheme, expected)) return;
        std.Io.sleep(client.io, .fromMilliseconds(10), .awake) catch {};
    }
    return error.TimedOutWaitingForCell;
}
