//! Hotkeys that switch profiles.
const config = @import("../config.zig");
const app_mod = @import("../app.zig");
const cycle_order = @import("cycle_order.zig");
const strings = @import("../util/strings.zig");
const log = @import("../log.zig");

const slog = log.Scoped("hotkeys");

pub fn cycle(app: *app_mod.App, current_profile: []const u8, is_forward: bool) void {
    const allocator = app.allocator;
    slog.info("{s} profile hotkey pressed", .{if (is_forward) "Next" else "Previous"});

    var profiles = config.listProfiles(allocator, app.io) catch |err| {
        slog.err("Failed to enumerate profiles: {}", .{err});
        return;
    };
    defer {
        for (profiles.items) |profile| allocator.free(profile);
        profiles.deinit(allocator);
    }

    if (profiles.items.len == 0) {
        slog.warn("No profiles found to cycle through", .{});
        return;
    }

    const current_index = strings.indexOfString(profiles.items, current_profile);
    var order = cycle_order.CycleOrder.init(current_index, profiles.items.len, .{ .is_forward = is_forward });
    const target_profile = profiles.items[order.next().?];
    slog.info("Cycling to {s} profile: {s} -> {s}", .{ if (is_forward) "next" else "previous", current_profile, target_profile });
    app.requestProfileSwitch(target_profile);
}

pub fn switchTo(app: *app_mod.App, current_profile: []const u8, profile_index: usize) void {
    const global_settings = &app.global_settings;
    if (profile_index >= global_settings.profileSwitchHotkeys.items.len) {
        slog.err("Failed to switch profile: hotkey index {} is out of range", .{profile_index});
        return;
    }

    const target_profile = global_settings.profileSwitchHotkeys.items[profile_index].targetProfile;
    slog.info("Switch to profile hotkey pressed: {s} -> {s}", .{ current_profile, target_profile });
    app.requestProfileSwitch(target_profile);
}
