//! Follows which window has focus and tells the thumbnail set, auto-minimize and hotkey cycling; hides the thumbnails once no EVE client has had it for a while.
const win32 = @import("../platform/win32.zig");
const app_mod = @import("../app.zig");
const scout = @import("../clients/scout.zig");
const set = @import("../thumbnail/set.zig");
const arrange = @import("../thumbnail/arrange.zig");
const log = @import("../log.zig");

const App = app_mod.App;
const ThumbnailSet = set.ThumbnailSet;
const slog = log.Scoped("focus");

/// Timer on the app's timer window, beside app.TICK_TIMER_ID, that auto-hides every thumbnail once no EVE window has had focus for hideDebounceMs.
pub const HIDE_DEBOUNCE_TIMER_ID: usize = 2;

/// App owns it, so a thumbnail set or hotkey manager rebuild keeps it; main thread only.
pub const FocusTracker = struct {
    foreground_hook: ?win32.HANDLE = null,
    is_hide_timer_pending: bool = false,
    /// The client hotkey cycling was last synced to; null while focus is outside EVE, so a client focused before its thumbnail exists is synced once it does.
    synced_hwnd: ?win32.HWND = null,
    /// For the return-to-last-app hotkey: the last focused window that isn't a tracked client, ours or the desktop shell.
    last_non_eve_foreground: ?win32.HWND = null,

    pub fn start(self: *FocusTracker) void {
        self.foreground_hook = win32.setWinEventHook(win32.EVENT_SYSTEM_FOREGROUND, foregroundProc);
        if (self.foreground_hook == null) slog.err("Failed to set up focus event hook", .{});
    }

    /// Before the timer window is destroyed.
    pub fn deinit(self: *FocusTracker, timer_hwnd: ?win32.HWND) void {
        if (self.foreground_hook) |hook| _ = win32.UnhookWinEvent(hook);
        self.foreground_hook = null;
        self.cancelHideTimer(timer_hwnd);
    }

    fn startHideTimer(self: *FocusTracker, timer_hwnd: ?win32.HWND, delay_ms: u32) void {
        const hwnd = timer_hwnd orelse return;
        if (win32.SetTimer(hwnd, HIDE_DEBOUNCE_TIMER_ID, delay_ms, null) == 0) {
            slog.err("Failed to start hide debounce timer", .{});
            return;
        }
        self.is_hide_timer_pending = true;
    }

    fn cancelHideTimer(self: *FocusTracker, timer_hwnd: ?win32.HWND) void {
        if (!self.is_hide_timer_pending) return;
        if (timer_hwnd) |hwnd| _ = win32.KillTimer(hwnd, HIDE_DEBOUNCE_TIMER_ID);
        self.is_hide_timer_pending = false;
    }
};

/// `hwnd`, a tracked client, took focus; false if focus has already moved on, since focus events can arrive late during rapid cycling.
pub fn onClientFocused(app: *App, hwnd: win32.HWND) bool {
    app.focus.cancelHideTimer(app.timer_hwnd);

    const current_foreground = win32.GetForegroundWindow();
    if (current_foreground != hwnd) {
        slog.debug("Ignoring stale focus change (target={*}, current foreground={*})", .{ hwnd, current_foreground });
        return false;
    }

    const thumbnail_set = app.thumbnail_set orelse return false;
    thumbnail_set.reconcileThumbnailStates(hwnd);
    if (thumbnail_set.hasEveClient(hwnd)) app.auto_minimizer.recordFocus(hwnd);
    syncHotkeys(app, thumbnail_set, hwnd);
    return true;
}

/// Per tick, after ThumbnailSet.update set the active client: records it for auto-minimize, and syncs hotkey cycling to it if it was renamed or only now has a thumbnail.
pub fn afterThumbnailSetUpdate(app: *App, thumbnail_set: *ThumbnailSet, name_changes: []const scout.NameChange) void {
    const active = thumbnail_set.active_source_hwnd orelse return;
    if (thumbnail_set.hasEveClient(active)) app.auto_minimizer.recordFocus(active);
    if (!thumbnail_set.hasThumbnail(active)) {
        app.focus.synced_hwnd = null;
        return;
    }

    // Cycle cursors are keyed by name and a rename fires no focus event, so the focused window must re-sync under its new one.
    const was_renamed = for (name_changes) |change| {
        if (change.hwnd == active) break true;
    } else false;
    if (was_renamed or app.focus.synced_hwnd != active) syncHotkeys(app, thumbnail_set, active);
}

/// The hide debounce timer fired, so no EVE window has had focus for hideDebounceMs.
pub fn onHideTimer(app: *App) void {
    app.focus.cancelHideTimer(app.timer_hwnd);
    const thumbnail_set = app.thumbnail_set orelse return;
    thumbnail_set.autoHideAfterFocusLoss();
}

/// Keeps cycle positions in step with the focused client.
fn syncHotkeys(app: *App, thumbnail_set: *ThumbnailSet, hwnd: win32.HWND) void {
    const thumbnail = thumbnail_set.getThumbnailBySourceHwnd(hwnd) orelse return;
    app.focus.synced_hwnd = hwnd;
    slog.debug("Tracked window focused: {s}", .{thumbnail.character_name});
    if (app.hotkey_manager) |manager| manager.updateFocusedCharacter(thumbnail.character_name, hwnd);
}

fn foregroundProc(_: win32.HANDLE, _: win32.DWORD, hwnd: win32.HWND, _: win32.LONG, _: win32.LONG, _: win32.DWORD, _: win32.DWORD) callconv(.c) void {
    const app = app_mod.g_app orelse return;
    const thumbnail_set = app.thumbnail_set orelse return;

    if (thumbnail_set.getThumbnailByOverlayHwnd(hwnd) != null) {
        slog.debug("Thumbnail window got focus (ignoring): {*}", .{hwnd});
        return;
    }

    // A newly-foregrounded topmost window gets inserted above ours in the z-order band; push back unless it's shell UI allowed to stay on top.
    const ex_style = win32.GetWindowLongPtrA(hwnd, win32.GWL_EXSTYLE);
    if (ex_style & win32.WS_EX_TOPMOST != 0 and !win32.isExplorerOwned(hwnd)) {
        arrange.reassertTopmost(thumbnail_set);
    }

    if (!thumbnail_set.hasThumbnail(hwnd)) {
        app.focus.synced_hwnd = null;
        if (!win32.isOwnProcessWindow(hwnd) and !win32.isDesktopShellWindow(hwnd)) app.focus.last_non_eve_foreground = hwnd;

        const auto_hide = thumbnail_set.config.shownAutoHide();
        if (auto_hide.is_enabled) {
            slog.debug("Untracked window focused (hwnd={*}), starting {}ms debounce timer (auto-hide on)", .{ hwnd, auto_hide.delay_ms });
            app.focus.startHideTimer(app.timer_hwnd, auto_hide.delay_ms);
        } else {
            slog.debug("Untracked window focused (hwnd={*}), ignoring (auto-hide off)", .{hwnd});
        }
        return;
    }

    _ = onClientFocused(app, hwnd);
}
