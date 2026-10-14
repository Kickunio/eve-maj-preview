//! Snapping a dragged window to screen edges, other thumbnails and saved (ghost) positions.
const win32 = @import("../platform/win32.zig");
const set = @import("../thumbnail/set.zig");
const monitors = @import("../layout/monitors.zig");
const ghost_groups = @import("ghost_groups.zig");
const snap_math = @import("snap_math.zig");
const log = @import("../log.zig");

const ThumbnailSet = set.ThumbnailSet;
const GhostGroup = ghost_groups.GhostGroup;
const slog = log.Scoped("drag");

pub const SnapPosition = snap_math.SnapPosition;

/// Screen edges, then thumbnail edges, then ghost positions, each snapping the previous result.
pub fn applySnapping(thumbnail_set: *ThumbnailSet, x: i32, y: i32, width: i32, height: i32, dragging_hwnd: win32.HWND) SnapPosition {
    if (!thumbnail_set.config.snapping.enabled) return .{ .x = x, .y = y };

    const threshold = thumbnail_set.config.snapping.threshold;
    var result = SnapPosition{ .x = x, .y = y };

    if (thumbnail_set.config.snapping.screenEdges) result = applyScreenEdgeSnapping(result.x, result.y, width, height, threshold, dragging_hwnd);
    if (thumbnail_set.config.snapping.thumbnailEdges) result = applyThumbnailEdgeSnapping(result.x, result.y, width, height, threshold, dragging_hwnd, thumbnail_set);
    if (thumbnail_set.config.snapping.ghostPositions) result = applyGhostSnapping(result.x, result.y, width, height, threshold, dragging_hwnd, thumbnail_set);

    return result;
}

pub fn applyScreenEdgeSnapping(x: i32, y: i32, width: i32, height: i32, threshold: i32, dragging_hwnd: win32.HWND) SnapPosition {
    return snap_math.screenEdges(x, y, width, height, threshold, monitors.nearestMonitorBounds(dragging_hwnd).bounds);
}

fn applyThumbnailEdgeSnapping(
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    threshold: i32,
    dragging_hwnd: win32.HWND,
    thumbnail_set: *const ThumbnailSet,
) SnapPosition {
    var snap = snap_math.EdgeSnap.init(x, y, width, height, threshold);
    for (thumbnail_set.thumbnails.items) |thumbnail| {
        if (thumbnail.hwnd == dragging_hwnd or thumbnail.text_hwnd == dragging_hwnd) continue;
        if (!win32.isWindow(thumbnail.hwnd)) continue;

        var other_rect: win32.RECT = undefined;
        if (!win32.toBool(win32.GetWindowRect(thumbnail.hwnd, &other_rect))) {
            slog.debug("Skipped snapping to '{s}': its position couldn't be read", .{thumbnail.character_name});
            continue;
        }

        snap.toward(other_rect);
    }
    return snap.position();
}

/// Snaps to a ghost's exact saved position when within `threshold` px (Chebyshev distance), else aligns edges against ghost rects like applyThumbnailEdgeSnapping does for live thumbnails.
fn applyGhostSnapping(x: i32, y: i32, width: i32, height: i32, threshold: i32, dragging_hwnd: win32.HWND, thumbnail_set: *ThumbnailSet) SnapPosition {
    // Non-thumbnail draggers (e.g. the notification history panel) own no character, so nothing is excluded from the ghost set.
    const character_name = if (thumbnail_set.getThumbnailByOverlayHwnd(dragging_hwnd)) |t| t.character_name else "";

    // Reuses GhostOverlay.show's cache; the list view's drag never shows it, so it gets an uncached copy.
    var owned_fallback: ?[]GhostGroup = null;
    defer if (owned_fallback) |fallback| ghost_groups.freeGroups(thumbnail_set.allocator, fallback);

    const groups: []const GhostGroup = thumbnail_set.ghost_overlay.groups orelse blk: {
        const fresh = ghost_groups.collect(thumbnail_set.allocator, thumbnail_set.config, character_name) catch |err| {
            slog.warn("Failed to collect ghost positions to snap to: {}", .{err});
            return .{ .x = x, .y = y };
        };
        owned_fallback = fresh;
        break :blk fresh;
    };

    var dock = snap_math.Dock.init(x, y, threshold);
    for (groups) |group| dock.consider(group.rect);

    var snap = snap_math.EdgeSnap.init(dock.position.x, dock.position.y, width, height, threshold);
    for (groups) |group| snap.toward(group.rect);
    return snap.position();
}
