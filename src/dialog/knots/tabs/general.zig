//! The configuration window's General tab: app-wide preferences, then, in Advanced Mode, logging, scanning, and the window filters that pick which applications are tracked; main thread only.
const std = @import("std");
const ui = @import("ui");
const config = @import("../../../config.zig");
const session = @import("../session.zig");
const bind = @import("../bind.zig");
const host = @import("../host.zig");
const style = @import("../style.zig");
const widgets = @import("../widgets.zig");
const window_picker = @import("../window_picker.zig");
const lang = @import("../../../lang/lang.zig");

const Rect = ui.component.Rect;
const Text = ui.component.Text;
const Button = ui.component.Button;
const ProfileRef = session.Ref(config.Config);
const FilterRef = session.Ref(config.WindowFilterConfig);

const NEW_FILTER_NAME = "New Filter";

var g_allocator: std.mem.Allocator = undefined;
var g_selected_index: usize = 0;
/// The Window Filters switch isn't saved; it starts on whenever the profile has filters.
var g_are_filters_enabled: ?bool = null;
/// The open "Pick Running Window" dropdown, under one filter.
var g_picker: ?window_picker.Picker = null;

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
}

/// Once the window has closed.
pub fn reset() void {
    window_picker.close(&g_picker);
    g_are_filters_enabled = null;
    g_selected_index = 0;
}

pub fn show(context: *ui.Frame) !void {
    try preferences(context);
    if (!session.global().get("advancedMode")) return;
    try logging(context);
    try scanning(context);
    try windowFilters(context);
}

fn preferences(context: *ui.Frame) !void {
    const section = try widgets.openSection(
        context,
        "Preferences",
        "Advanced Mode reveals power-user settings across the app (extra tabs, position/spacing parameters, snapping, layout system, and more). These preferences are global and apply across all profiles.",
        &style.section,
    );
    const global = session.global();
    try bind.choice(context, global, "language", "Language");
    try widgets.hintText(context, .src(@src()), "Also used for the app's on-screen messages.");
    try bind.toggle(context, global, "advancedMode", "Advanced Mode");
    try widgets.hintText(context, .src(@src()), "Shows extra, rarely changed settings and tabs.");
    const was_on_top = global.get("alwaysOnTop");
    try bind.toggle(context, global, "alwaysOnTop", "Always on Top");
    try widgets.hintText(context, .src(@src()), "Keeps this window above other windows.");
    if (global.get("alwaysOnTop") != was_on_top) host.setAlwaysOnTop(!was_on_top);
    try section.close(context);
}

fn logging(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Logging", "How much detail is written to the log file.", &style.section);
    try bind.choice(context, session.global(), "logLevel", "Log Level");
    try widgets.hintText(context, .src(@src()), "Use Debug when reporting a problem.");
    try section.close(context);
}

fn scanning(context: *ui.Frame) !void {
    const section = try widgets.openSection(context, "Scanning", "How often to check for new EVE windows.", &style.section);
    try bind.number(context, session.profile().child("timer"), "scanIntervalMs", "Scan Interval", .{ .shows_seconds = true, .unit = "s" });
    try widgets.hintText(context, .src(@src()), "How often to look for opened or closed clients.");
    try section.close(context);
}

fn windowFilters(context: *ui.Frame) !void {
    const profile = session.profile();
    var is_enabled = g_are_filters_enabled orelse (profile.ptr.windowFilters.items.len > 0);
    const section = try widgets.openSwitchedSection(context, "Window Filters", "Configure which applications to track. Each filter can match by window class name and executable name.", &style.section, .{ .is_on = &is_enabled });
    if (section.is_flipped) g_are_filters_enabled = is_enabled;
    try widgets.hintText(context, .src(@src()), "When off, only EVE windows are shown.");

    const options = try widgets.openGroup(context, .src(@src()), is_enabled);
    try filterList(context, profile);
    try options.close(context);
    try section.close(context);
}

/// The built-in EVE filter is the profile default and isn't editable here, so it's left out of the roster.
fn isBuiltIn(filter: *const config.WindowFilterConfig) bool {
    return std.mem.eql(u8, filter.name, config.WindowFilterConfig.DEFAULT.name);
}

fn filterList(context: *ui.Frame, profile: ProfileRef) !void {
    const filters = profile.ptr.windowFilters.items;
    var first_editable: ?usize = null;
    var is_selected_editable = false;
    for (filters, 0..) |*filter, index| {
        if (isBuiltIn(filter)) continue;
        if (first_editable == null) first_editable = index;
        if (index == g_selected_index) is_selected_editable = true;
    }
    if (first_editable) |first| {
        if (!is_selected_editable) g_selected_index = first;
    }
    const master_detail = Rect{ .key = .src(@src()), .style = &style.master_detail };
    _ = try master_detail.open(context);
    const list = try widgets.openRoster(context, .str("knots.filter.roster"), &style.roster_filters, false);
    if (first_editable == null) {
        try widgets.boxedText(context, .src(@src()), "No window filters yet.", &style.roster_empty, &style.roster_empty_text);
    }

    const arena = context.arena();
    for (filters, 0..) |*filter, index| {
        if (isBuiltIn(filter)) continue;
        const is_selected = index == g_selected_index;
        const row = Button{ .key = ui.Key.str("knots.filter.row").indexed(index), .style = if (is_selected) &style.roster_row_selected else &style.roster_row };
        if ((try widgets.openRosterRow(context, row)).clicked and !is_selected) {
            g_selected_index = index;
            context.requestRedraw();
        }
        const name = if (filter.name.len > 0) filter.name else try lang.format(arena, "New Filter {n}", .{ .n = index + 1 });
        try context.e(Text{
            .selectable = false,
            .key = ui.Key.str("knots.filter.name").indexed(index),
            .content = name,
            .style = if (is_selected) &style.roster_name_selected else &style.roster_name,
        });
        const badge = if (filter.enabled) "" else lang.text("Disabled");
        if (badge.len > 0) try context.e(Text{ .selectable = false, .key = ui.Key.str("knots.filter.badge").indexed(index), .content = badge, .style = &style.roster_badge });
        try widgets.fitRosterRow(context, name, 0, badge);
        try row.close(context);
    }
    const added: ?FilterRef = if (try list.close(context, .{ .add_label = "Add Window Filter" }) == .add) profile.append("windowFilters", .{ .name = lang.text(NEW_FILTER_NAME), .enabled = true }) else null;
    if (added) |filter| g_selected_index = filter.index;
    if (first_editable == null and added == null) {
        const empty = Rect{ .key = .src(@src()), .style = &style.detail_fit };
        _ = try empty.open(context);
        try widgets.paragraph(context, .src(@src()), "Add a window filter under the list to start tracking another application.");
        try empty.close(context);
    } else {
        try filterDetail(context, profile, g_selected_index);
    }
    try master_detail.close(context);
}

fn filterDetail(context: *ui.Frame, profile: ProfileRef, index: usize) !void {
    const filter = profile.item("windowFilters", index);
    const stack = Rect{ .key = .src(@src()), .style = &style.detail_fit };
    _ = try stack.open(context);

    const header = try widgets.openDetailHeader(context, .src(@src()));
    try context.e(Text{ .selectable = false, .key = .src(@src()), .content = lang.text("Filter Name"), .style = &style.inline_label });
    const name_before = try context.arena().dupe(u8, filter.get("name"));
    try bind.textBox(context, filter, "name", "e.g., EVE Online");
    const name_after = filter.get("name");
    const removed = try widgets.confirmButton(context, ui.Key.str("knots.filter.remove").indexed(index), "Remove", "Confirm", &style.plain_button, &style.confirm_button);
    try header.close(context);
    if (!std.mem.eql(u8, name_before, name_after)) carryRename(profile, std.mem.trim(u8, name_before, " "), std.mem.trim(u8, name_after, " "));

    var is_enabled: bool = filter.get("enabled");
    if (try widgets.switchRow(context, ui.Key.str("knots.filter.enabled").indexed(index), "Enabled", &is_enabled)) filter.set("enabled", is_enabled);
    try widgets.hintText(context, ui.Key.str("knots.filter.enabled.hint").indexed(index), "When off, this filter matches nothing.");
    const classes = try widgets.openBinding(context, ui.Key.str("knots.filter.classes").indexed(index), "Window Classes");
    try bind.csvBox(context, filter, "class_names", "e.g., trinityWindow");
    try classes.close(context);
    try widgets.hintText(context, ui.Key.str("knots.filter.classes.hint").indexed(index), "Optional. Leave blank to match by Executable Names only.");
    const executables = try widgets.openBinding(context, ui.Key.str("knots.filter.exes").indexed(index), "Executable Names");
    try bind.csvBox(context, filter, "executable_names", "e.g., exefile.exe");
    try executables.close(context);
    try widgets.hintText(context, ui.Key.str("knots.filter.exes.hint").indexed(index), "Separate names with commas.");
    const detect = try widgets.openBinding(context, ui.Key.str("knots.filter.detect").indexed(index), "Detect");
    if (try widgets.glyphButton(context, ui.Key.str("knots.filter.pick").indexed(index), .refresh, "Pick Running Window", &style.plain_button, false)) window_picker.open(g_allocator, &g_picker, index);
    try detect.close(context);
    try widgets.hintText(context, ui.Key.str("knots.filter.detect.hint").indexed(index), "Pick an open window to fill in this filter.");
    try picker(context, profile, filter);
    try stack.close(context);

    if (removed) removeFilter(profile, index);
}

/// Picking a window fills in its class and executable, and names the filter after the executable.
fn picker(context: *ui.Frame, profile: ProfileRef, filter: FilterRef) !void {
    const chosen = try window_picker.select(context, &g_picker, .str("knots.filter.picker"), filter.index) orelse return;
    filter.setStrings("class_names", &.{chosen.class});
    filter.setStrings("executable_names", &.{chosen.executable});
    const friendly = if (std.ascii.endsWithIgnoreCase(chosen.executable, ".exe")) chosen.executable[0 .. chosen.executable.len - ".exe".len] else chosen.executable;
    filter.set("name", friendly);
    addCharacterIfMissing(profile, friendly);
    window_picker.close(&g_picker);
}

/// A filter's windows show up as a character named after it, so one is added when a window is picked.
fn addCharacterIfMissing(profile: ProfileRef, name: []const u8) void {
    if (characterIndex(profile, name) != null) return;
    if (profile.append("characters", .{})) |added| added.set("name", name);
}

fn characterIndex(profile: ProfileRef, name: []const u8) ?usize {
    for (profile.ptr.characters.items, 0..) |character, index| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, character.name, " "), name)) return index;
    }
    return null;
}

/// A filter's windows are named after it, so its character entry and hotkey group places follow a rename.
fn carryRename(profile: ProfileRef, old_name: []const u8, new_name: []const u8) void {
    if (old_name.len == 0 or new_name.len == 0 or std.mem.eql(u8, old_name, new_name)) return;
    if (characterIndex(profile, old_name)) |entry| {
        const clash = characterIndex(profile, new_name);
        if (clash == null or clash == entry) profile.item("characters", entry).set("name", new_name);
    }
    for (0..profile.ptr.hotkeyGroups.items.len) |group_index| {
        const group = profile.item("hotkeyGroups", group_index);
        const members = group.ptr.characters.items;
        const old_index = for (members, 0..) |member, at| {
            if (std.mem.eql(u8, member, old_name)) break at;
        } else continue;
        const is_already_member = for (members) |member| {
            if (std.mem.eql(u8, member, new_name)) break true;
        } else false;
        if (is_already_member) group.remove("characters", old_index) else group.setStringAt("characters", old_index, new_name);
    }
}

fn removeFilter(profile: ProfileRef, index: usize) void {
    const name = std.mem.trim(u8, profile.ptr.windowFilters.items[index].name, " ");
    if (name.len > 0) {
        if (characterIndex(profile, name)) |entry| profile.remove("characters", entry);
    }
    profile.remove("windowFilters", index);
    if (g_selected_index >= index) g_selected_index -|= 1;
    window_picker.close(&g_picker);
}
