//! The saved positions a drag shows as ghosts and snaps to, stacked ones merged into one; no I/O.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const config_mod = @import("../config.zig");
const spaces = @import("../layout/spaces.zig");

const Config = config_mod.Config;

/// One saved-position outline; `names` is the comma-joined list of every character sharing that exact rect, owned by whoever holds the group slice.
pub const GhostGroup = struct {
    rect: win32.RECT,
    names: []const u8,
};

/// Saved positions for every character but `exclude_character`, grouped by exact rect (identical x/y/w/h counts as stacked); free with freeGroups.
pub fn collect(allocator: std.mem.Allocator, config: *const Config, exclude_character: []const u8) ![]GhostGroup {
    const RawEntry = struct { name: []const u8, rect: win32.RECT };

    var raw: std.ArrayList(RawEntry) = .empty;
    defer raw.deinit(allocator);

    for (config.characters.items) |character_config| {
        if (std.mem.eql(u8, character_config.name, exclude_character)) continue;
        const position = character_config.position orelse continue;
        // A space ignores the saved position, so it's no snap target.
        if (spaces.spaceFor(config, character_config.name) != null) continue;
        const size = config.handPlacedSize(character_config.name);
        try raw.append(allocator, .{
            .name = character_config.name,
            .rect = .{ .left = position.x, .top = position.y, .right = position.x + size.width, .bottom = position.y + size.height },
        });
    }

    var groups: std.ArrayList(GhostGroup) = .empty;
    errdefer {
        for (groups.items) |group| allocator.free(group.names);
        groups.deinit(allocator);
    }

    const used = try allocator.alloc(bool, raw.items.len);
    defer allocator.free(used);
    @memset(used, false);

    for (raw.items, 0..) |entry, i| {
        if (used[i]) continue;
        used[i] = true;

        var names: std.ArrayList(u8) = .empty;
        defer names.deinit(allocator);
        try names.appendSlice(allocator, entry.name);

        for (raw.items[i + 1 ..], i + 1..) |other, j| {
            if (used[j] or !std.meta.eql(entry.rect, other.rect)) continue;
            used[j] = true;
            try names.appendSlice(allocator, ", ");
            try names.appendSlice(allocator, other.name);
        }

        const joined = try names.toOwnedSlice(allocator);
        errdefer allocator.free(joined);
        try groups.append(allocator, .{ .rect = entry.rect, .names = joined });
    }

    return groups.toOwnedSlice(allocator);
}

pub fn freeGroups(allocator: std.mem.Allocator, groups: []GhostGroup) void {
    for (groups) |group| allocator.free(group.names);
    allocator.free(groups);
}

const testing = std.testing;

fn testConfig(characters: []config_mod.CharacterConfig) Config {
    return .{ .allocator = testing.allocator, .profile_name = "", .characters = .fromOwnedSlice(characters) };
}

fn savedAt(name: []const u8, x: i32, y: i32) config_mod.CharacterConfig {
    return .{ .name = name, .position = .{ .x = x, .y = y } };
}

test "characters saved at the same rect share one ghost, named in profile order" {
    var characters = [_]config_mod.CharacterConfig{ savedAt("Alpha", 10, 20), savedAt("Bravo", 500, 20), savedAt("Charlie", 10, 20) };
    const config = testConfig(&characters);
    const groups = try collect(testing.allocator, &config, "");
    defer freeGroups(testing.allocator, groups);

    const size = config.handPlacedSize("Alpha");
    try testing.expectEqual(@as(usize, 2), groups.len);
    try testing.expectEqualStrings("Alpha, Charlie", groups[0].names);
    try testing.expectEqual(win32.RECT{ .left = 10, .top = 20, .right = 10 + size.width, .bottom = 20 + size.height }, groups[0].rect);
    try testing.expectEqualStrings("Bravo", groups[1].names);
}

test "the dragged character and characters with no saved position get no ghost" {
    var characters = [_]config_mod.CharacterConfig{ savedAt("Alpha", 10, 20), savedAt("Bravo", 500, 20), .{ .name = "Charlie" } };
    const config = testConfig(&characters);
    const groups = try collect(testing.allocator, &config, "Alpha");
    defer freeGroups(testing.allocator, groups);

    try testing.expectEqual(@as(usize, 1), groups.len);
    try testing.expectEqualStrings("Bravo", groups[0].names);
}

test "a character's own thumbnail size sets its ghost's size" {
    var characters = [_]config_mod.CharacterConfig{.{ .name = "Alpha", .position = .{ .x = 0, .y = 0 }, .thumbnailSize = .{ .width = 300, .height = 150 } }};
    const config = testConfig(&characters);
    const groups = try collect(testing.allocator, &config, "");
    defer freeGroups(testing.allocator, groups);

    try testing.expectEqual(win32.RECT{ .left = 0, .top = 0, .right = 300, .bottom = 150 }, groups[0].rect);
}
