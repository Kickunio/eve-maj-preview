//! Round-trip time from each EVE client to the server it's connected to, by ICMP echo.
const std = @import("std");
const win32 = @import("../platform/win32.zig");
const scout = @import("../clients/scout.zig");
const log = @import("../log.zig");

const slog = log.Scoped("activity_ping");

const GAME_SERVER_PORT = 26000;
const ECHO_TIMEOUT_MS = 1000;
const ECHO_PAYLOAD = "eve-maj ping";
/// Room for the reply, an ICMP error's 8 bytes, and the IO_STATUS_BLOCK an asynchronous echo also writes.
const REPLY_BUFFER_SIZE = @sizeOf(win32.ICMP_ECHO_REPLY) + ECHO_PAYLOAD.len + 8 + 2 * @sizeOf(usize);
/// The table can grow between the size query and the read.
const TABLE_READ_ATTEMPTS = 3;
const TABLE_HEADER_DWORDS = 1;
const ROW_DWORDS = @sizeOf(win32.MIB_TCPROW_OWNER_PID) / @sizeOf(win32.DWORD);

pub const ClientPing = struct {
    is_connected: bool,
    /// Null until the first reply, and after a timeout.
    rtt_ms: ?u32,
};

/// Heap-allocated, since Windows writes the reply into it after IcmpSendEcho2 returns.
const Echo = struct {
    address: win32.IPAddr,
    /// Manual-reset; signalled once the reply, or the timeout, has been written.
    event: win32.HANDLE,
    is_pending: bool = false,
    /// Null until the first reply, and after a timeout.
    rtt_ms: ?u32 = null,
    reply: [REPLY_BUFFER_SIZE]u8 align(@alignOf(win32.ICMP_ECHO_REPLY)) = undefined,
};

/// Main thread only, so unlocked.
pub const PingTracker = struct {
    allocator: std.mem.Allocator,
    /// Null when ICMP couldn't be opened, so no client ever shows a ping.
    icmp: ?win32.HANDLE,
    /// Each client process's game server.
    server_addresses: std.AutoHashMap(win32.DWORD, win32.IPAddr),
    /// Owned; one per server, shared by every client connected to it.
    echoes: std.ArrayList(*Echo) = .empty,
    /// Reused between reads; DWORDs, since the table's fields are.
    table: std.ArrayList(win32.DWORD) = .empty,

    pub fn init(allocator: std.mem.Allocator) PingTracker {
        const handle = win32.IcmpCreateFile();
        const is_open = handle != win32.INVALID_HANDLE_VALUE;
        if (!is_open) slog.warn("Failed to open an ICMP handle, so ping won't show: {}", .{win32.GetLastError()});
        return .{ .allocator = allocator, .icmp = if (is_open) handle else null, .server_addresses = .init(allocator) };
    }

    /// Can wait up to ECHO_TIMEOUT_MS for an echo still on its way.
    pub fn deinit(self: *PingTracker) void {
        for (self.echoes.items) |echo| self.destroyEcho(echo);
        self.echoes.deinit(self.allocator);
        self.table.deinit(self.allocator);
        self.server_addresses.deinit();
        if (self.icmp) |handle| _ = win32.IcmpCloseHandle(handle);
    }

    pub fn pingOf(self: *const PingTracker, process_id: win32.DWORD) ClientPing {
        const address = self.server_addresses.get(process_id) orelse return .{ .is_connected = false, .rtt_ms = null };
        const echo = self.findEcho(address) orelse return .{ .is_connected = true, .rtt_ms = null };
        return .{ .is_connected = true, .rtt_ms = echo.rtt_ms };
    }

    /// Cheap enough for every tick; true if an echo finished, so some client's ping may have changed.
    pub fn poll(self: *PingTracker) bool {
        var has_finished = false;
        for (self.echoes.items) |echo| {
            if (!echo.is_pending or win32.WaitForSingleObject(echo.event, 0) != win32.WAIT_OBJECT_0) continue;
            echo.is_pending = false;
            echo.rtt_ms = replyTime(echo);
            has_finished = true;
        }
        return has_finished;
    }

    /// Finds each client's server, then echoes every server not still waiting on its last reply.
    pub fn sample(self: *PingTracker, windows: []const scout.EveWindow) void {
        const icmp = self.icmp orelse return;
        self.refreshServerAddresses(windows) catch |err| {
            slog.warn("Failed to find the clients' game servers, so ping won't update: {}", .{err});
            return;
        };
        self.pruneEchoes();

        var it = self.server_addresses.valueIterator();
        while (it.next()) |address| {
            const echo = self.echoFor(address.*) catch |err| {
                slog.warn("Failed to set up a ping to a game server: {}", .{err});
                continue;
            };
            if (!echo.is_pending) send(icmp, echo);
        }
    }

    fn refreshServerAddresses(self: *PingTracker, windows: []const scout.EveWindow) !void {
        self.server_addresses.clearRetainingCapacity();
        const rows = try self.readTcpTable();
        for (windows) |eve_window| {
            if (eve_window.process_id == 0) continue;
            const address = serverAddressOf(rows, eve_window.process_id) orelse continue;
            try self.server_addresses.put(eve_window.process_id, address);
        }
    }

    /// Borrows from self.table until the next read.
    fn readTcpTable(self: *PingTracker) ![]const win32.MIB_TCPROW_OWNER_PID {
        for (0..TABLE_READ_ATTEMPTS) |_| {
            var size: win32.DWORD = @intCast(self.table.items.len * @sizeOf(win32.DWORD));
            const buffer: ?*anyopaque = if (self.table.items.len > 0) self.table.items.ptr else null;
            const status = win32.GetExtendedTcpTable(buffer, &size, win32.FALSE, win32.AF_INET, win32.TCP_TABLE_OWNER_PID_CONNECTIONS, 0);
            if (status == 0) return tableRows(self.table.items);
            if (status != win32.ERROR_INSUFFICIENT_BUFFER) return error.GetTcpTableFailed;
            try self.table.resize(self.allocator, (@as(usize, size) + @sizeOf(win32.DWORD) - 1) / @sizeOf(win32.DWORD));
        }
        return error.GetTcpTableFailed;
    }

    fn findEcho(self: *const PingTracker, address: win32.IPAddr) ?*Echo {
        for (self.echoes.items) |echo| {
            if (echo.address == address) return echo;
        }
        return null;
    }

    fn echoFor(self: *PingTracker, address: win32.IPAddr) !*Echo {
        if (self.findEcho(address)) |echo| return echo;
        const event = win32.CreateEventA(null, win32.TRUE, win32.FALSE, null) orelse return error.CreateEventFailed;
        errdefer _ = win32.CloseHandle(event);
        const echo = try self.allocator.create(Echo);
        errdefer self.allocator.destroy(echo);
        echo.* = .{ .address = address, .event = event };
        try self.echoes.append(self.allocator, echo);
        return echo;
    }

    /// Keeps a pending echo, since its reply is still to be written into it.
    fn pruneEchoes(self: *PingTracker) void {
        var i: usize = 0;
        while (i < self.echoes.items.len) {
            const echo = self.echoes.items[i];
            if (echo.is_pending or self.isServerInUse(echo.address)) {
                i += 1;
                continue;
            }
            _ = self.echoes.swapRemove(i);
            self.destroyEcho(echo);
        }
    }

    fn isServerInUse(self: *const PingTracker, address: win32.IPAddr) bool {
        var it = self.server_addresses.valueIterator();
        while (it.next()) |server| {
            if (server.* == address) return true;
        }
        return false;
    }

    fn destroyEcho(self: *PingTracker, echo: *Echo) void {
        // Leaked rather than freed while Windows may still write into it.
        if (echo.is_pending and win32.WaitForSingleObject(echo.event, ECHO_TIMEOUT_MS) != win32.WAIT_OBJECT_0) return;
        _ = win32.CloseHandle(echo.event);
        self.allocator.destroy(echo);
    }
};

fn send(icmp: win32.HANDLE, echo: *Echo) void {
    _ = win32.ResetEvent(echo.event);
    const result = win32.IcmpSendEcho2(icmp, echo.event, null, null, echo.address, ECHO_PAYLOAD, ECHO_PAYLOAD.len, null, &echo.reply, echo.reply.len, ECHO_TIMEOUT_MS);
    // Given an event, success is 0 with ERROR_IO_PENDING, and the event signals the reply.
    const last_error = win32.GetLastError();
    if (result != 0 or last_error != win32.ERROR_IO_PENDING) {
        // Debug: an unreachable network would repeat this every sample.
        const octets: [4]u8 = @bitCast(echo.address);
        slog.debug("Failed to ping {d}.{d}.{d}.{d}: {}", .{ octets[0], octets[1], octets[2], octets[3], last_error });
        echo.rtt_ms = null;
        return;
    }
    echo.is_pending = true;
}

/// Null on a timeout, or an ICMP error such as an unreachable host.
fn replyTime(echo: *Echo) ?u32 {
    if (win32.IcmpParseReplies(&echo.reply, echo.reply.len) == 0) return null;
    const reply: *const win32.ICMP_ECHO_REPLY = @ptrCast(&echo.reply);
    if (reply.Status != win32.IP_SUCCESS) return null;
    return reply.RoundTripTime;
}

/// Trusts the table's row count no further than `table` goes.
fn tableRows(table: []const win32.DWORD) []const win32.MIB_TCPROW_OWNER_PID {
    if (table.len < TABLE_HEADER_DWORDS) return &.{};
    const row_count = @min(table[0], (table.len - TABLE_HEADER_DWORDS) / ROW_DWORDS);
    const rows: [*]const win32.MIB_TCPROW_OWNER_PID = @ptrCast(table[TABLE_HEADER_DWORDS..].ptr);
    return rows[0..row_count];
}

/// The remote address of `process_id`'s established connection to the game server's port.
fn serverAddressOf(rows: []const win32.MIB_TCPROW_OWNER_PID, process_id: win32.DWORD) ?win32.IPAddr {
    for (rows) |row| {
        if (row.dwOwningPid != process_id or row.dwState != win32.MIB_TCP_STATE_ESTAB) continue;
        if (std.mem.bigToNative(u16, @truncate(row.dwRemotePort)) != GAME_SERVER_PORT) continue;
        return row.dwRemoteAddr;
    }
    return null;
}

const testing = std.testing;

fn testRow(process_id: win32.DWORD, state: win32.DWORD, remote_address: win32.IPAddr, remote_port: u16) win32.MIB_TCPROW_OWNER_PID {
    return .{
        .dwState = state,
        .dwLocalAddr = 0,
        .dwLocalPort = 0,
        .dwRemoteAddr = remote_address,
        .dwRemotePort = std.mem.nativeToBig(u16, remote_port),
        .dwOwningPid = process_id,
    };
}

test "serverAddressOf picks the client's established game server connection over chat and HTTPS" {
    const rows = [_]win32.MIB_TCPROW_OWNER_PID{
        testRow(42, win32.MIB_TCP_STATE_ESTAB, 1, 443),
        testRow(42, win32.MIB_TCP_STATE_ESTAB, 2, 5222),
        testRow(7, win32.MIB_TCP_STATE_ESTAB, 3, GAME_SERVER_PORT),
        testRow(42, 8, 4, GAME_SERVER_PORT),
        testRow(42, win32.MIB_TCP_STATE_ESTAB, 5, GAME_SERVER_PORT),
    };
    try testing.expectEqual(@as(?win32.IPAddr, 5), serverAddressOf(&rows, 42));
    try testing.expectEqual(@as(?win32.IPAddr, null), serverAddressOf(&rows, 99));
}

test "tableRows ignores a row count the buffer can't hold" {
    const table = [_]win32.DWORD{ 5, 1, 2, 3, 4, 5, 6 };
    const rows = tableRows(&table);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(@as(win32.DWORD, 6), rows[0].dwOwningPid);
    try testing.expectEqual(@as(usize, 0), tableRows(&.{}).len);
}
