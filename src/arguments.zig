//! The command line, parsed once into what main.zig acts on; no I/O.
const std = @import("std");

/// Each slice borrows from the arguments it was parsed from.
pub const Arguments = struct {
    /// From `--protocol <url>`, forwarded to the running instance.
    protocol_url: ?[]const u8 = null,
    /// From `--profile <name>` or `-p <name>`; the last one given wins.
    profile: ?[]const u8 = null,
    should_open_config: bool = false,
    /// The first argument that couldn't be used, reported only once a protocol URL has been forwarded, which never fails on it.
    invalid: ?Invalid = null,
};

pub const Invalid = union(enum) {
    missing_profile_name,
    /// Borrows the argument.
    unknown: []const u8,
};

/// `args` includes the program name first, as the process receives them.
pub fn parse(args: []const []const u8) Arguments {
    var result: Arguments = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--profile") or std.mem.eql(u8, arg, "-p")) {
            index += 1;
            if (index < args.len) {
                result.profile = args[index];
            } else if (result.invalid == null) {
                result.invalid = .missing_profile_name;
            }
        } else if (std.mem.eql(u8, arg, "--config")) {
            result.should_open_config = true;
        } else if (std.mem.eql(u8, arg, "--protocol")) {
            index += 1;
            if (index < args.len) result.protocol_url = args[index];
        } else if (result.invalid == null) {
            result.invalid = .{ .unknown = arg };
        }
    }
    return result;
}

const testing = std.testing;

test "parse reads a profile, the config flag and a protocol URL" {
    const parsed = parse(&.{ "app.exe", "-p", "Mining", "--config", "--protocol", "evemajpreview://switch/Pilot" });
    try testing.expectEqualStrings("Mining", parsed.profile.?);
    try testing.expect(parsed.should_open_config);
    try testing.expectEqualStrings("evemajpreview://switch/Pilot", parsed.protocol_url.?);
    try testing.expectEqual(null, parsed.invalid);
}

test "parse takes the word after --profile as the name, even one that looks like a flag" {
    const parsed = parse(&.{ "app.exe", "--profile", "--config" });
    try testing.expectEqualStrings("--config", parsed.profile.?);
    try testing.expect(!parsed.should_open_config);
}

test "parse reports --profile with no name after it" {
    const parsed = parse(&.{ "app.exe", "--profile" });
    try testing.expectEqual(null, parsed.profile);
    try testing.expectEqual(Invalid.missing_profile_name, parsed.invalid.?);
}

test "parse keeps the protocol URL beside an unknown argument" {
    const parsed = parse(&.{ "app.exe", "--bogus", "--protocol", "evemajpreview://open", "--other" });
    try testing.expectEqualStrings("evemajpreview://open", parsed.protocol_url.?);
    try testing.expectEqualStrings("--bogus", parsed.invalid.?.unknown);
}

test "parse ignores a trailing --protocol with no URL" {
    const parsed = parse(&.{ "app.exe", "--protocol" });
    try testing.expectEqual(null, parsed.protocol_url);
    try testing.expectEqual(null, parsed.invalid);
}
