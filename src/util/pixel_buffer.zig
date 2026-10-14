//! Filling, outlining and alpha-fixing rects in a raw 0xAARRGGBB pixel buffer; no I/O.
const std = @import("std");

/// A `width` x `height` buffer of 0xAARRGGBB pixels, rows packed with no padding; borrows `pixels`.
pub const Canvas = struct {
    pixels: [*]u32,
    width: usize,
    height: usize,
};

/// A rect's part inside a pixel buffer, and how thick its outline can be.
const ClippedRect = struct { left: usize, top: usize, right: usize, bottom: usize, thickness: usize };

/// GDI text rendering leaves the alpha byte at 0; sets alpha=255 on every pixel with non-zero RGB still at alpha 0 within the given rect, without touching alpha other drawing code already set.
pub fn fixTextAlphaRect(canvas: Canvas, x: i32, y: i32, rect_width: usize, rect_height: usize) void {
    const width = canvas.width;
    const start_x: usize = @intCast(@max(0, x));
    const start_y: usize = @intCast(@max(0, y));
    const end_x = @min(start_x + rect_width, width);
    const end_y = @min(start_y + rect_height, canvas.height);
    if (end_x <= start_x or end_y <= start_y) return;

    for (start_y..end_y) |pixel_y| {
        const row = canvas.pixels[pixel_y * width + start_x .. pixel_y * width + end_x];
        for (row) |*pixel| {
            const value = pixel.*;
            if ((value >> 24) == 0 and (value & 0x00FF_FFFF) != 0) {
                pixel.* = value | 0xFF00_0000;
            }
        }
    }
}

pub fn fixTextAlpha(canvas: Canvas) void {
    fixTextAlphaRect(canvas, 0, 0, canvas.width, canvas.height);
}

/// No-ops if the rect would overrun the buffer's row width or its height.
pub fn fillRect(canvas: Canvas, x: usize, y: usize, rect_width: usize, rect_height: usize, argb: u32) void {
    const width = canvas.width;
    const end_y = y + rect_height;
    const end_x = x + rect_width;
    if (end_x > width or end_y > canvas.height) return;
    for (y..end_y) |pixel_y| {
        @memset(canvas.pixels[pixel_y * width + x .. pixel_y * width + end_x], argb);
    }
}

/// Corners are cut with per-row insets (no anti-aliasing), which is fine at the small radii UI buttons use.
pub fn fillRoundedRect(canvas: Canvas, x: usize, y: usize, rect_width: usize, rect_height: usize, radius: usize, argb: u32) void {
    const corner_radius = @min(radius, @min(rect_width, rect_height) / 2);
    const radius_f: f32 = @floatFromInt(corner_radius);
    for (0..rect_height) |row| {
        const from_edge = @min(row, rect_height - 1 - row);
        var inset: usize = 0;
        if (from_edge < corner_radius) {
            const dy = radius_f - @as(f32, @floatFromInt(from_edge)) - 0.5;
            inset = @intFromFloat(@round(radius_f - @sqrt(radius_f * radius_f - dy * dy)));
        }
        fillRect(canvas, x + inset, y + row, rect_width - 2 * inset, 1, argb);
    }
}

/// Draws a `thickness`-px outline of a rect placed anywhere inside the canvas, clamped to its bounds.
pub fn drawRectOutline(canvas: Canvas, x: i32, y: i32, rect_width: usize, rect_height: usize, thickness: usize, color: u32) void {
    const clipped = clipToCanvas(canvas, x, y, rect_width, rect_height, thickness) orelse return;
    const line = clipped.thickness;
    fillRect(canvas, clipped.left, clipped.top, clipped.right - clipped.left, line, color);
    fillRect(canvas, clipped.left, clipped.bottom - line, clipped.right - clipped.left, line, color);
    fillRect(canvas, clipped.left, clipped.top, line, clipped.bottom - clipped.top, color);
    fillRect(canvas, clipped.right - line, clipped.top, line, clipped.bottom - clipped.top, color);
}

/// Like drawRectOutline, in `dash`-px dashes with gaps as long, each side starting from its top or left corner.
pub fn drawDashedRectOutline(canvas: Canvas, x: i32, y: i32, rect_width: usize, rect_height: usize, thickness: usize, dash: usize, color: u32) void {
    if (dash == 0) return;
    const clipped = clipToCanvas(canvas, x, y, rect_width, rect_height, thickness) orelse return;
    const line = clipped.thickness;
    var pixel_x = clipped.left;
    while (pixel_x < clipped.right) : (pixel_x += 2 * dash) {
        const run = @min(dash, clipped.right - pixel_x);
        fillRect(canvas, pixel_x, clipped.top, run, line, color);
        fillRect(canvas, pixel_x, clipped.bottom - line, run, line, color);
    }
    var pixel_y = clipped.top;
    while (pixel_y < clipped.bottom) : (pixel_y += 2 * dash) {
        const run = @min(dash, clipped.bottom - pixel_y);
        fillRect(canvas, clipped.left, pixel_y, line, run, color);
        fillRect(canvas, clipped.right - line, pixel_y, line, run, color);
    }
}

/// A 1px border round the whole canvas with `radius` rounded corners; outside them the pixels are cleared so the desktop shows through.
pub fn drawRoundedFrame(canvas: Canvas, radius: usize, argb: u32) void {
    const pixels = canvas.pixels;
    const width = canvas.width;
    const height = canvas.height;
    fillRect(canvas, 0, 0, width, 1, argb);
    fillRect(canvas, 0, height - 1, width, 1, argb);
    fillRect(canvas, 0, 0, 1, height, argb);
    fillRect(canvas, width - 1, 0, 1, height, argb);
    if (width < 2 * radius or height < 2 * radius) return;

    const radius_f: f32 = @floatFromInt(radius);
    for (0..radius) |dy| {
        for (0..radius) |dx| {
            // From the corner arc's centre to this pixel's centre.
            const offset_x = radius_f - @as(f32, @floatFromInt(dx)) - 0.5;
            const offset_y = radius_f - @as(f32, @floatFromInt(dy)) - 0.5;
            const distance = @sqrt(offset_x * offset_x + offset_y * offset_y);
            const pixel: u32 = if (distance > radius_f) 0 else if (distance > radius_f - 1) argb else continue;
            pixels[dy * width + dx] = pixel;
            pixels[dy * width + width - 1 - dx] = pixel;
            pixels[(height - 1 - dy) * width + dx] = pixel;
            pixels[(height - 1 - dy) * width + width - 1 - dx] = pixel;
        }
    }
}

/// Null when nothing of the rect is inside the canvas.
fn clipToCanvas(canvas: Canvas, x: i32, y: i32, rect_width: usize, rect_height: usize, thickness: usize) ?ClippedRect {
    const left: usize = @intCast(std.math.clamp(x, 0, @as(i32, @intCast(canvas.width))));
    const top: usize = @intCast(std.math.clamp(y, 0, @as(i32, @intCast(canvas.height))));
    const right = @min(canvas.width, left + rect_width);
    const bottom = @min(canvas.height, top + rect_height);
    if (right <= left or bottom <= top) return null;
    return .{ .left = left, .top = top, .right = right, .bottom = bottom, .thickness = @min(thickness, @min(right - left, bottom - top)) };
}

const testing = std.testing;

test "fillRect fills only its rect and skips one that would overrun" {
    var buffer: [4 * 3]u32 = @splat(0);
    const canvas: Canvas = .{ .pixels = &buffer, .width = 4, .height = 3 };
    fillRect(canvas, 1, 1, 2, 1, 7);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 0, 0, 7, 7, 0, 0, 0, 0, 0 }, &buffer);
    fillRect(canvas, 3, 0, 2, 1, 9);
    try testing.expectEqual(@as(u32, 0), buffer[3]);
}

test "drawRectOutline moves a rect starting off the buffer onto its edge" {
    var buffer: [4 * 4]u32 = @splat(0);
    drawRectOutline(.{ .pixels = &buffer, .width = 4, .height = 4 }, -1, -1, 3, 3, 1, 5);
    try testing.expectEqualSlices(u32, &.{ 5, 5, 5, 0, 5, 0, 5, 0, 5, 5, 5, 0, 0, 0, 0, 0 }, &buffer);
}

test "fixTextAlphaRect makes drawn text opaque without touching blank or already-set pixels" {
    var buffer = [_]u32{ 0x00000000, 0x00123456, 0x80123456 };
    fixTextAlphaRect(.{ .pixels = &buffer, .width = 3, .height = 1 }, 0, 0, 3, 1);
    try testing.expectEqualSlices(u32, &.{ 0x00000000, 0xFF123456, 0x80123456 }, &buffer);
}

test "drawRoundedFrame borders the buffer and clears outside its corners" {
    var buffer: [8 * 8]u32 = @splat(0xFFFFFFFF);
    drawRoundedFrame(.{ .pixels = &buffer, .width = 8, .height = 8 }, 3, 0xFF000000);
    try testing.expectEqual(@as(u32, 0), buffer[0]);
    try testing.expectEqual(@as(u32, 0xFF000000), buffer[4]);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), buffer[4 * 8 + 4]);
}
