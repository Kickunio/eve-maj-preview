//! Hands evemajpreview:// URLs from a second process to the running instance over WM_COPYDATA.
const win32 = @import("../platform/win32.zig");
const log = @import("../log.zig");

const slog = log.Scoped("protocol");

/// The hidden timer window's class, by which a second launch finds the running instance.
pub const MAIN_WINDOW_CLASS = "EVE_TIMER_CLASS";
/// The dwData of a URL; 1-9 were older formats, skipped so a stale sender's message is ignored rather than misread.
const URL_MESSAGE_KIND: usize = 10;
/// How long a second launch waits for the running instance to take a command, so a hung one can't strand it.
const SEND_TIMEOUT_MS = 5000;

pub fn findExistingInstance() ?win32.HWND {
    return win32.FindWindowA(MAIN_WINDOW_CLASS, null);
}

/// The running instance parses it; a protocol URL never starts one.
pub fn forwardToRunningInstance(text: []const u8) !void {
    const existing_hwnd = findExistingInstance() orelse {
        slog.err("Failed to forward '{s}': no running instance", .{text});
        return error.MissingInstance;
    };
    try send(existing_hwnd, text);
    slog.info("Protocol command forwarded", .{});
}

/// Synchronous, so `text` only has to outlive the call; logs its own failure, such as a hung or unreachable instance.
pub fn send(hwnd: win32.HWND, text: []const u8) !void {
    const copy_data: win32.COPYDATASTRUCT = .{
        .dwData = URL_MESSAGE_KIND,
        .cbData = @intCast(text.len),
        .lpData = if (text.len > 0) text.ptr else null,
    };
    if (win32.SendMessageTimeoutA(hwnd, win32.WM_COPYDATA, 0, win32.ptrToLparam(&copy_data), win32.SMTO_ABORTIFHUNG | win32.SMTO_BLOCK, SEND_TIMEOUT_MS, null) == 0) {
        slog.err("Failed to forward '{s}' to the running instance: error {d}", .{ text, win32.GetLastError() });
        return error.SendFailed;
    }
}

/// The URL `send` passed, borrowed from `copy_data`; null for any other WM_COPYDATA.
pub fn receivedUrl(copy_data: *const win32.COPYDATASTRUCT) ?[]const u8 {
    if (copy_data.dwData != URL_MESSAGE_KIND) return null;
    const data = copy_data.lpData orelse return "";
    return @as([*]const u8, @ptrCast(data))[0..copy_data.cbData];
}
