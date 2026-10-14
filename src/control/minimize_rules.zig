//! Whether auto-minimize minimizes a client this tick, decided from facts about it; no I/O.
const std = @import("std");

pub const Settings = struct {
    delay_ms: u64,
    /// With no EVE client focused, spares each monitor's last active client.
    exempts_last_active_on_focus_loss: bool,
};

pub const Client = struct {
    /// False for a window filter's window, which is never minimized.
    is_eve_client: bool,
    is_dragging: bool,
    is_focused: bool,
    was_minimized: bool,
    /// The character's Exclude from Auto-Minimize setting.
    is_excluded: bool,
    /// Since it was last focused or minimized.
    inactive_ms: u64,
    /// On another monitor than the focused EVE client; false while no EVE client has focus.
    is_on_other_monitor: bool,
    /// The last client focused on its monitor, or one with no live client recorded there.
    is_last_active_on_its_monitor: bool,
};

/// Checked in order; a monitor's last active client is spared while focus is on another monitor, or outside EVE when the setting asks.
pub fn shouldMinimize(settings: Settings, client: Client, eve_has_focus: bool) bool {
    if (!client.is_eve_client or client.is_dragging or client.is_focused or client.was_minimized) return false;
    const is_spared_by_focus_loss = settings.exempts_last_active_on_focus_loss and !eve_has_focus;
    if ((client.is_on_other_monitor or is_spared_by_focus_loss) and client.is_last_active_on_its_monitor) return false;
    if (client.inactive_ms < settings.delay_ms) return false;
    return !client.is_excluded;
}

const testing = std.testing;

const SETTINGS: Settings = .{ .delay_ms = 1000, .exempts_last_active_on_focus_loss = false };

/// An EVE client idle past the delay, on the focused monitor and not its last active one.
fn idle() Client {
    return .{
        .is_eve_client = true,
        .is_dragging = false,
        .is_focused = false,
        .was_minimized = false,
        .is_excluded = false,
        .inactive_ms = 5000,
        .is_on_other_monitor = false,
        .is_last_active_on_its_monitor = false,
    };
}

/// idle() with one fact changed.
fn with(comptime field: []const u8, value: anytype) Client {
    var client = idle();
    @field(client, field) = value;
    return client;
}

test "a client idle past the delay is minimized" {
    try testing.expect(shouldMinimize(SETTINGS, idle(), true));
}

test "a client idle for less than the delay is kept" {
    try testing.expect(!shouldMinimize(SETTINGS, with("inactive_ms", 999), true));
    try testing.expect(shouldMinimize(SETTINGS, with("inactive_ms", 1000), true));
}

test "a window filter's window, a dragged, focused, minimized or excluded client is never minimized" {
    try testing.expect(!shouldMinimize(SETTINGS, with("is_eve_client", false), true));
    try testing.expect(!shouldMinimize(SETTINGS, with("is_dragging", true), true));
    try testing.expect(!shouldMinimize(SETTINGS, with("is_focused", true), true));
    try testing.expect(!shouldMinimize(SETTINGS, with("was_minimized", true), true));
    try testing.expect(!shouldMinimize(SETTINGS, with("is_excluded", true), true));
}

test "the last active client on another monitor is spared, but not one on the focused monitor" {
    var other_monitor = with("is_on_other_monitor", true);
    other_monitor.is_last_active_on_its_monitor = true;
    try testing.expect(!shouldMinimize(SETTINGS, other_monitor, true));
    try testing.expect(shouldMinimize(SETTINGS, with("is_on_other_monitor", true), true));
    try testing.expect(shouldMinimize(SETTINGS, with("is_last_active_on_its_monitor", true), true));
}

test "with focus outside EVE, a monitor's last active client is spared only when the setting asks" {
    const last_active = with("is_last_active_on_its_monitor", true);
    const exempting: Settings = .{ .delay_ms = SETTINGS.delay_ms, .exempts_last_active_on_focus_loss = true };
    try testing.expect(!shouldMinimize(exempting, last_active, false));
    try testing.expect(shouldMinimize(SETTINGS, last_active, false));
    try testing.expect(shouldMinimize(exempting, idle(), false));
}
