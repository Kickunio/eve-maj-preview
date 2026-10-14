//! The configuration window's status line: the outcome of the last action, shown in the footer for a few seconds; main thread only.
const std = @import("std");
const lang = @import("../../lang/lang.zig");
const log = @import("../../log.zig");

const slog = log.Scoped("dialog_knots");

const MAX_LENGTH = 160;
const SHOW_MS = 5000;
/// Longer, so an error can be read in full.
const FAILURE_SHOW_MS = 10000;

pub const Kind = enum { info, success, failure };

var g_buf: [MAX_LENGTH]u8 = undefined;
var g_length: usize = 0;
var g_kind: Kind = .info;
/// Set by show until takeShownMs reports it.
var g_is_new: bool = false;

/// `english` translated, with its {placeholders} filled from `args` (see wording.fill); truncated to MAX_LENGTH.
pub fn show(message_kind: Kind, english: []const u8, args: anytype) void {
    var writer: std.Io.Writer = .fixed(&g_buf);
    lang.write(&writer, english, args) catch |err| {
        slog.warn("Failed to fit a status message, showing what fit: {}", .{err});
    };
    g_length = writer.end;
    g_kind = message_kind;
    g_is_new = true;
}

/// How long to show the message shown since the last call, if any, before clearing it.
pub fn takeShownMs() ?u32 {
    if (!g_is_new) return null;
    g_is_new = false;
    if (g_length == 0) return null;
    return switch (g_kind) {
        .info, .success => SHOW_MS,
        .failure => FAILURE_SHOW_MS,
    };
}

pub fn clear() void {
    g_length = 0;
}

/// Borrows from this module until the next show or clear.
pub fn text() []const u8 {
    return g_buf[0..g_length];
}

pub fn kind() Kind {
    return g_kind;
}
