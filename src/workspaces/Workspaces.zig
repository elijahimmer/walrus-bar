//! The widget frontend for whatever workspaces provider
//! is running, (if any).
//! TODO: Make workspaces with less max workspaces than max_workspace_count work

pub const Workspaces = @This();

/// Represents one single workspace
pub const Workspace = struct {
    area: Rect,
    id: WorkspaceID,
    char: u21,

    should_redraw: bool = true,
};
/// the list type used containing many `Workspace`s
pub const WorkspacesArray = BoundedArray(Workspace, max_workspace_count);
/// The list type used for containing all the possible workspace symbols.
/// Stores as decoded unicode so that we don't have to do the expensive
/// unicode iteration and decoding to get a symbol.
pub const WorkspaceSymbolArray = BoundedArray(u21, max_workspace_count);

pub const WorkspacesConfig = struct {
    pub const text_color_comment = "The text color of the workspaces";
    pub const background_color_comment = "The background color of the workspaces";
    pub const hovered_text_color_comment = "The text color of the workspaces when hovered";
    pub const hovered_background_color_comment = "The background color of the workspaces when hovered";
    pub const active_text_color_comment = "The text color of the workspaces when active";
    pub const active_background_color_comment = "The background color of the workspaces when active";
    pub const spacing_comment = " The space (in pixels) between two workspaces";

    pub const padding_comment = "The general padding for each size between the letters.";

    pub const padding_north_comment = "Overrides general padding the top side";
    pub const padding_south_comment = "Overrides general padding the bottom side";
    pub const padding_east_comment = "Overrides general padding the right side";
    pub const padding_west_comment = "Overrides general padding the left side";

    pub const symbols_comment = "A list of UTF8 characters, each one corresponding to a workspace in order.";

    //// times 2 because each character is 2 bytes wide.
    //// UPDATE IF THE STRING IS EVER CHANGED!
    symbols: []const u8 = "ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ"[0 .. max_workspace_count * 2],

    text_color: Color = colors.rose,
    background_color: Color = colors.surface,

    hovered_text_color: Color = colors.gold,
    hovered_background_color: Color = colors.hl_med,

    active_text_color: Color = colors.gold,
    active_background_color: Color = colors.pine,

    spacing: Size = 0,

    padding: Size = 0,

    padding_north: ?Size = null,
    padding_south: ?Size = null,
    padding_east: ?Size = null,
    padding_west: ?Size = null,
};

/// The global workspace state, given by the workspaces worker.
const workspace_state = &WorkspaceState.global;

/// Tells the widget to fill it's entire background not
/// taken up by a workspace. Used when removing a workspace to get
/// rid of the left-behinds.
fill_background: bool = false,

/// The inner widget for dynamic dispatch and such.
widget: Widget,

/// The padding of the widget.
padding: Padding,

/// the spacing in between each workspace
workspace_spacing: Size,

/// the background color of a normal workspace (not hovered or active)
background_color: Color,
/// the text color of a normal workspace (not hovered or active)
text_color: Color,

/// The index of the workspace the cursor is over.
/// Reset this every time the workspaces array is changed.
hover_workspace_idx: ?WorkspaceIndex = null,

/// The index of the workspace the cursor was over
/// when this widget was last drawn.
hover_workspace_drawn: ?WorkspaceIndex = null,

/// the background color of whichever workspace is hovered by the cursor.
hover_workspace_background: Color,
/// the text color of whichever workspace is hovered by the cursor.
hover_workspace_text: Color,

/// the background color of whichever workspace is active.
active_workspace_background: Color,
/// the text color of whichever workspace is active.
active_workspace_text: Color,
/// The ID of whichever workspace is active.
active_workspace: WorkspaceID,

/// The list of all current workspaces.
workspaces: WorkspacesArray,
/// The list of all the possible workspace symbols.
workspaces_symbols: WorkspaceSymbolArray,

/// Returns the width this widget wants to take up.
pub fn getWidth(self: *Workspaces) Size {
    const area = self.widget.area.removePadding(self.padding) orelse return 0;
    return (area.height + self.workspace_spacing) * max_workspace_count + self.padding.west + self.padding.east;
}

/// Sets the area of this widget to the area given,
/// and tells it to redraw if needed.
pub fn setArea(self: *Workspaces, area: Rect) void {
    defer self.widget.area = area;
    defer self.widget.full_redraw = true;

    // TODO: Make this have a dynamic max_workspace_count for the size it can hold.
    const area_without_padding = area.removePadding(self.padding) orelse return;
    assert(area_without_padding.height * max_workspace_count <= area_without_padding.width);
}

/// Given a total height, give the font size for workspace symbols.
pub inline fn fontScalingFactor(height: Size) Size {
    return height * 3 / 4;
}

pub fn correctnessCheck(workspaces: *const Workspaces) void {
    // make sure the workspaces are sorted.
    assert(std.sort.isSorted(Workspace, workspaces.workspaces.constSlice(), {}, struct {
        pub fn lessThan(_: void, lhs: Workspace, rhs: Workspace) bool {
            return lhs.id < rhs.id;
        }
    }.lessThan));

    // ensure each workspace has a unique id.
    for (workspaces.workspaces.constSlice(), 0..) |wksp, idx| {
        for (workspaces.workspaces.constSlice()[idx + 1 ..]) |wksp2| assert(wksp.id != wksp2.id);
    }
}

/// Updates the state of the widget with `updateState`, then proceeds
/// to draw any changes in state (or redraw fully if needed).
pub fn draw(self: *Workspaces, draw_context: *DrawContext) !void {
    // check initial state.
    if (std.debug.runtime_safety) self.correctnessCheck();
    self.updateState();

    if (std.debug.runtime_safety) self.correctnessCheck();
    defer if (std.debug.runtime_safety) self.correctnessCheck();

    defer self.widget.full_redraw = false;

    const full_redraw = draw_context.full_redraw or self.widget.full_redraw;

    if (full_redraw) {
        self.widget.area.drawArea(draw_context, self.background_color);
    }

    // if there is no area after padding, just return. Nothing more to draw
    const area = self.widget.area.removePadding(self.padding) orelse return;

    const font_size = fontScalingFactor(area.height);

    self.hover_workspace_idx = if (self.widget.last_motion) |lm| self.pointToWorkspaceIndex(lm) else null;
    defer self.hover_workspace_drawn = self.hover_workspace_idx;

    for (self.workspaces.slice(), 0..) |*wksp, idx| {
        const is_hovered = self.hover_workspace_idx != null and idx == self.hover_workspace_idx.?;
        const was_hovered = self.hover_workspace_drawn != null and idx == self.hover_workspace_drawn.?;
        const still_hovered = is_hovered and was_hovered;

        if (full_redraw or wksp.should_redraw or (is_hovered or was_hovered) and !still_hovered) {
            defer wksp.should_redraw = false;

            const background_color = if (is_hovered)
                self.hover_workspace_background
            else if (wksp.id == self.active_workspace)
                self.active_workspace_background
            else
                self.background_color;

            const text_color = if (is_hovered)
                self.hover_workspace_text
            else if (wksp.id == self.active_workspace)
                self.active_workspace_text
            else
                self.text_color;

            wksp.area.drawArea(draw_context, background_color);

            log.debug("loading workspace {} then char {}", .{ wksp.id, wksp.char });
            assert(wksp.char != 0);
            freetype_context.drawChar(.{
                .draw_context = draw_context,

                .bounding_box = options.workspaces_outlines,

                .transform = Transform.identity,

                .text_color = text_color,

                .area = wksp.area,
                .width = .{ .fixed = wksp.area.width },
                .char = wksp.char,
                .font_size = font_size,

                .hori_align = .center,
                .vert_align = .center,
            });

            if (!full_redraw) {
                draw_context.damage(wksp.area);
            }
        }
    }

    defer self.fill_background = false;
    // fill in the left-behinds
    if (self.fill_background and !full_redraw) {
        const start = if (self.workspaces.len > 0)
            self.workspaces.len * (area.height + self.workspace_spacing)
        else
            0;

        var area_to_fill = area;

        assert(start < area_to_fill.width);

        area_to_fill.x += start;
        area_to_fill.width -= start;

        area_to_fill.drawArea(draw_context, self.background_color);
        draw_context.damage(area_to_fill);
    }
}

/// Returns the workspace ID for a given workspace, or if not found, a replacement glyph.
fn getWorkspaceSymbol(self: *const Workspaces, id: WorkspaceID) u21 {
    // above zero because WorkspaceID start at 1.
    if (id > 0 and id <= self.workspaces_symbols.len) return self.workspaces_symbols.get(@intCast(id - 1));
    return '?'; // unknown workspace
}

/// Update the state to be in sync with the workspaces worker.
fn updateState(self: *Workspaces) void {
    const rc = workspace_state.rc.load(.monotonic);
    // workspaces worker turned off
    if (rc == 0) {
        workspace_state.init() catch |err| {
            switch (err) {
                error.ServiceNotFound => {},
                else => {
                    log.warn("Failed to restart workspaces state with {s}", .{@errorName(err)});
                },
            }

            return;
        };
    }

    if (!workspace_state.rwlock.tryLockShared()) {
        // TODO: Remove this once we decouple update from draw.
        // if it fails to lock, just don't update this draw.
        return;
    }
    defer workspace_state.rwlock.unlockShared();

    // if there is no widget area after padding, just don't. There is no point.
    const area = self.widget.area.removePadding(self.padding) orelse return;

    switch (std.math.order(workspace_state.workspaces.len, self.workspaces.len)) {
        // add more
        .gt => {
            var workspace_area = Rect{
                .x = area.x + self.workspaces.len * (area.height + self.workspace_spacing),
                .y = area.y,
                .width = area.height, // set width to height
                .height = area.height,
            };

            for (self.workspaces.len..workspace_state.workspaces.len) |_| {
                self.widget.area.assertContains(workspace_area);

                self.workspaces.appendAssumeCapacity(.{
                    .area = workspace_area,
                    .char = 0,
                    .id = 0,
                });

                workspace_area.x += area.height + self.workspace_spacing;
            }
        },
        // remove some
        .lt => {
            self.workspaces.resize(workspace_state.workspaces.len) catch unreachable;
            self.fill_background = true;
        },
        // juuuuuuuuuust right
        .eq => {},
    }

    defer self.active_workspace = workspace_state.active_workspace;

    var newly_active_found = false;
    var prev_active_found = false;

    assert(workspace_state.workspaces.len == self.workspaces.len);
    defer assert(workspace_state.workspaces.len == self.workspaces.len);

    var counter: usize = 0;
    for (workspace_state.workspaces.constSlice(), self.workspaces.slice()) |wk_id, *wksp| {
        assert(counter < workspace_state.workspaces.len); // counter
        defer counter += 1;

        defer wksp.id = wk_id;
        const wk_symbol = self.getWorkspaceSymbol(wk_id);
        defer assert(wksp.char == wk_symbol);

        const newly_active = wk_id == workspace_state.active_workspace and wk_id != self.active_workspace;
        const prev_active = wk_id != workspace_state.active_workspace and wk_id == self.active_workspace;

        if (newly_active) {
            assert(!newly_active_found);
            newly_active_found = true;
        }
        if (prev_active) {
            assert(!prev_active_found);
            prev_active_found = true;
        }

        wksp.should_redraw = wksp.should_redraw or newly_active or prev_active;

        if (wksp.id != wk_id) {
            wksp.char = wk_symbol;
            wksp.should_redraw = true;
        }
    }
}

// converts a point into the index of the workspace that contains that point,
// if one indeed contains the point.
fn pointToWorkspaceIndex(self: *const Workspaces, point: Point) ?WorkspaceIndex {
    // if the widget is empty after it's padding
    const area = self.widget.area.removePadding(self.padding) orelse return null;
    if (!area.containsPoint(point)) return null;
    const x_local = point.x - area.x;

    // if you aren't over any workspaces due to the padding.
    if (!area.containsPoint(point)) return null;

    // if you are between workspaces, you aren't hovering above one.
    if (x_local % (area.height + self.workspace_spacing) > area.height) return null;

    const workspace_idx_raw = x_local / (area.height + self.workspace_spacing);
    const workspace_idx = math.cast(WorkspaceIndex, workspace_idx_raw) orelse return null;

    if (workspace_idx >= self.workspaces.len) return null;
    return workspace_idx;
}

// Changes workspaces to whichever workspace was clicked on.
pub fn click(self: *const Workspaces, button: MouseButton) void {
    if (button != .left_click) return;
    assert(self.widget.last_motion != null);

    const point = self.widget.last_motion.?;

    if (self.pointToWorkspaceIndex(point)) |wksp_idx| {
        const wksp = self.workspaces.get(wksp_idx);
        if (wksp.id == self.active_workspace) return;

        WorkspaceState.setWorkspace(wksp.id) catch |err| {
            log.warn("Failed to set workspace with: {s}", .{@errorName(err)});
        };
    }
}

/// Initializes the workspaces widget.
/// Must call deinit to destroy.
pub fn init(area: Rect, config: WorkspacesConfig) !Workspaces {
    if (options.workspaces_provider == .none) return error.@"None Selected";

    assert(unicode.utf8ValidateSlice(config.symbols));

    workspace_state.init() catch |err| switch (err) {
        // workspaces state in valid on service not found, it will just be empty.
        error.ServiceNotFound => {},
        else => return err,
    };

    // convert given string of workspaces into a decoded unicode array
    var symbols = WorkspaceSymbolArray{};
    var utf8_iter = unicode.Utf8Iterator{ .bytes = config.symbols, .i = 0 };

    // No loop counter, append bounds it already.
    while (utf8_iter.nextCodepoint()) |char| {
        symbols.append(char) catch {
            log.warn("Too many workspace symbols given, only the first {} will be used. Increase max_workspace_count", .{max_workspace_count});
            break;
        };
    }

    return .{
        .background_color = config.background_color,
        .text_color = config.text_color,

        .hover_workspace_background = config.hovered_background_color,
        .hover_workspace_text = config.hovered_text_color,

        .active_workspace = undefined,
        .active_workspace_background = config.active_background_color,
        .active_workspace_text = config.active_text_color,

        .workspaces = .{},
        .workspaces_symbols = symbols,

        .padding = .{
            .north = config.padding_north orelse config.padding,
            .south = config.padding_south orelse config.padding,
            .east = config.padding_east orelse config.padding,
            .west = config.padding_west orelse config.padding,
        },

        .workspace_spacing = config.spacing,

        .widget = .{
            .vtable = Widget.generateVTable(Workspaces),
            .area = area,
        },
    };
}

// Deinitializes the widget, and frees the Workspaces.
// This should only be called if this Widget was created
// with `new`, (or allocated manually).
pub fn deinitWidget(widget: *Widget, allocator: Allocator) void {
    const self: *Workspaces = @fieldParentPtr("widget", widget);

    self.deinit();
    allocator.destroy(self);
}

/// Deinitializes the widget. This should only be called if
/// this Widget was created with `init`.
pub fn deinit(self: *Workspaces) void {
    workspace_state.deinit();
    self.* = undefined;
}

test {
    std.testing.refAllDecls(@This());
}

const seat_utils = @import("../seat_utils.zig");
const MouseButton = seat_utils.MouseButton;

const WorkspaceState = @import("WorkspaceState.zig");
const WorkspaceIndex = WorkspaceState.WorkspaceIndex;
const WorkspaceID = WorkspaceState.WorkspaceID;
const max_workspace_count = WorkspaceState.max_workspace_count;

const DrawContext = @import("../DrawContext.zig");

const FreeTypeContext = @import("../FreeTypeContext.zig");
const freetype_context = &FreeTypeContext.global;

const drawing = @import("../drawing.zig");
const Transform = drawing.Transform;
const Padding = drawing.Padding;
const Widget = drawing.Widget;
const Point = drawing.Point;
const Rect = drawing.Rect;
const Size = drawing.Size;

const colors = @import("../colors.zig");
const Color = colors.Color;

const options = @import("options");

const std = @import("std");
const unicode = std.unicode;
const posix = std.posix;
const math = std.math;

const Allocator = std.mem.Allocator;
const BoundedArray = std.BoundedArray;
const assert = std.debug.assert;

const log = std.log.scoped(.Workspaces);
