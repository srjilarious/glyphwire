//! Vendored, modified fork of zmd (https://github.com/jetzig-framework/zmd),
//! MIT licensed. See README.md in this directory for what's been changed
//! and why.
//!
//! Two entry points: `parse` renders HTML through zmd's original token
//! stream and `Formatters`; `Document.parse` (a glyphwire addition) builds
//! a structured block/inline tree for a renderer that lays text out
//! itself.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const Writer = std.Io.Writer;

pub const Node = @import("Node.zig");
pub const Ast = @import("Ast.zig");
pub const tokens = @import("tokens.zig");
pub const Formatters = @import("Formatters.zig");
pub const Document = @import("Document.zig");
pub const Inline = @import("Inline.zig");

pub fn parse(
    allocator: Allocator,
    input: []const u8,
    formatters: Formatters,
) ![]const u8 {
    var arena: ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var nodes: ArrayList(*Node) = .empty;
    defer nodes.deinit(alloc);

    const normalized = try normalizeInput(alloc, input);
    var ast: Ast = try .init(alloc, normalized);
    defer ast.deinit(alloc);
    const root = try ast.parse(alloc);
    try nodes.append(alloc, root);

    var aw: Writer.Allocating = .init(alloc);
    defer aw.deinit();

    try nodes.items[0].toHtml(
        alloc,
        normalized,
        &aw.writer,
        0,
        formatters,
    );

    return allocator.dupe(u8, try aw.toOwnedSlice());
}

// Normalize text to unix-style linebreaks and ensure ending with a linebreak to simplify
// Windows compatibility.
fn normalizeInput(allocator: Allocator, input: []const u8) ![]const u8 {
    const output = try std.mem.replaceOwned(u8, allocator, input, "\r\n", "\n");
    if (std.mem.endsWith(u8, output, "\n")) return output;

    return std.mem.concat(allocator, u8, &[_][]const u8{ output, "\n" });
}
