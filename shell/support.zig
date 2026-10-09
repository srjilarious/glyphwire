// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

//! `shell_support`: parser, prompt helpers, config. See CONTRIBUTING.md.

pub const parse = @import("parse.zig");
pub const envassign = @import("envassign.zig");
pub const complete = @import("applib").pathcomplete;
pub const glob = @import("glob.zig");
pub const handshake = @import("handshake.zig");
pub const flushgate = @import("flushgate.zig");
pub const crashlog = @import("crashlog.zig");
pub const config = @import("config.zig");
pub const script_engine = @import("script_engine.zig");
pub const keyencode = @import("glyphwire").key_encode;
pub const pty = @import("glyphwire").pty;
pub const pipeexec = @import("glyphwire").pipeexec;
pub const prompt_template = @import("prompt_template.zig");
pub const browsescroll = @import("browsescroll.zig");
pub const promptrow = @import("promptrow.zig");
pub const openaction = @import("openaction.zig");
pub const logicalpath = @import("logicalpath.zig");
pub const remotecmd = @import("remotecmd.zig");
pub const embed = @import("embed.zig");
