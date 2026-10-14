//! Whether a notification shows on a thumbnail: the settings and suppression rules, decided from facts about the thumbnail; no I/O.
const std = @import("std");
const config_notifications = @import("../config/notifications.zig");

const NotificationConfig = config_notifications.NotificationConfig;
const NotificationTypeConfig = config_notifications.NotificationTypeConfig;

/// Why a notification is held back.
pub const Hold = enum { notifications_off, character_muted, type_off, focused, recently_clicked, throttled };

pub const Situation = struct {
    is_muted: bool,
    is_focused: bool,
    /// Since the thumbnail was last clicked; large when it never was.
    since_click_ms: u64,
    /// Shown too recently for the type's throttle.
    is_throttled: bool,
};

/// Null when it shows; checked in order, so the first rule that holds it back is the one reported.
pub fn holdReason(settings: *const NotificationConfig, type_config: NotificationTypeConfig, situation: Situation) ?Hold {
    if (!settings.enabled) return .notifications_off;
    if (situation.is_muted) return .character_muted;
    if (!type_config.enabled) return .type_off;
    if (type_config.suppress_when_focused and situation.is_focused) return .focused;
    if (type_config.suppress_when_clicked and situation.since_click_ms < settings.suppress_click_duration_ms) return .recently_clicked;
    if (situation.is_throttled) return .throttled;
    return null;
}

const testing = std.testing;

/// Nothing about the thumbnail holds a notification back.
fn quiet() Situation {
    return .{ .is_muted = false, .is_focused = false, .since_click_ms = 1_000_000, .is_throttled = false };
}

/// quiet() with one fact changed.
fn with(comptime field: []const u8, value: anytype) Situation {
    var situation = quiet();
    @field(situation, field) = value;
    return situation;
}

test "a notification shows when nothing holds it back" {
    try testing.expectEqual(null, holdReason(&.{}, .{}, quiet()));
}

test "the notification switch, a muted character and a turned-off type each hold it back" {
    try testing.expectEqual(Hold.notifications_off, holdReason(&.{ .enabled = false }, .{}, quiet()).?);
    try testing.expectEqual(Hold.character_muted, holdReason(&.{}, .{}, with("is_muted", true)).?);
    try testing.expectEqual(Hold.type_off, holdReason(&.{}, .{ .enabled = false }, quiet()).?);
}

test "focus holds it back only for a type set to suppress while focused" {
    try testing.expectEqual(null, holdReason(&.{}, .{ .suppress_when_focused = false }, with("is_focused", true)));
    try testing.expectEqual(Hold.focused, holdReason(&.{}, .{ .suppress_when_focused = true }, with("is_focused", true)).?);
}

test "a click holds it back until the suppress-after-click time has passed" {
    const settings: NotificationConfig = .{ .suppress_click_duration_ms = 2000 };
    const type_config: NotificationTypeConfig = .{ .suppress_when_clicked = true };
    try testing.expectEqual(Hold.recently_clicked, holdReason(&settings, type_config, with("since_click_ms", 1999)).?);
    try testing.expectEqual(null, holdReason(&settings, type_config, with("since_click_ms", 2000)));
    try testing.expectEqual(null, holdReason(&settings, .{ .suppress_when_clicked = false }, with("since_click_ms", 0)));
}

test "a throttled type is held back" {
    try testing.expectEqual(Hold.throttled, holdReason(&.{}, .{}, with("is_throttled", true)).?);
}

test "with several rules applying, the first in order is reported" {
    const everything: Situation = .{ .is_muted = true, .is_focused = true, .since_click_ms = 0, .is_throttled = true };
    const suppressing: NotificationTypeConfig = .{ .suppress_when_focused = true, .suppress_when_clicked = true };
    try testing.expectEqual(Hold.notifications_off, holdReason(&.{ .enabled = false }, suppressing, everything).?);
    try testing.expectEqual(Hold.character_muted, holdReason(&.{}, suppressing, everything).?);
    try testing.expectEqual(Hold.focused, holdReason(&.{}, suppressing, with("is_focused", true)).?);
}
