//! The widget frontend for whatever workspaces provider
//! is running, (if any).

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
workspace_spacing: u16,

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
pub fn getWidth(self: *Workspaces) u31 {
    const area = self.widget.area.removePadding(self.padding) orelse return 0;
    return (area.height + self.workspace_spacing) * max_workspace_count;
}

/// Sets the area of this widget to the area given,
/// and tells it to redraw if needed.
pub fn setArea(self: *Workspaces, area: Rect) void {
    // TODO: Make this have a dynamic max_workspace_count for the size it can hold.
    assert(area.height * max_workspace_count <= area.width);

    self.widget.area = area;
    self.widget.full_redraw = true;
}

/// Given a total height, give the font size for workspace symbols.
pub inline fn fontScalingFactor(height: u31) u31 {
    return height * 3 / 4;
}

/// Updates the state of the widget with `updateState`, then proceeds
/// to draw any changes in state (or redraw fully if needed).
pub fn draw(self: *Workspaces, draw_context: *DrawContext) anyerror!void {
    try self.updateState();

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
    if (id > 0 and id <= max_workspace_count) return self.workspaces_symbols.get(@intCast(id - 1));
    return '?'; // unknown workspace
}

/// Update the state to be in sync with the workspaces worker.
fn updateState(self: *Workspaces) !void {
    workspace_state.rwlock.lockShared();
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
                    .id = undefined,
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

    assert(workspace_state.workspaces.len == self.workspaces.len);
    for (workspace_state.workspaces.constSlice(), self.workspaces.slice()) |wk_id, *wksp| {
        wksp.id = wk_id;
        const wk_symbol = self.getWorkspaceSymbol(wk_id);

        const newly_active = wk_id == workspace_state.active_workspace and wk_id != self.active_workspace;
        const prev_active = wk_id == self.active_workspace and wk_id != workspace_state.active_workspace;

        wksp.should_redraw = wksp.should_redraw or newly_active or prev_active;

        if (wksp.char != wk_symbol) {
            wksp.char = wk_symbol;
            wksp.should_redraw = true;
        }
    }

    self.active_workspace = workspace_state.active_workspace;
}

// converts a point into the index of the workspace that contains that point,
// if one indeed contains the point.
fn pointToWorkspaceIndex(self: *const Workspaces, point: Point) ?WorkspaceIndex {
    // if the widget is empty after it's padding
    const area = self.widget.area.removePadding(self.padding) orelse return null;
    const x_local = point.x - area.x;

    // if you aren't over any workspaces due to the padding.
    if (!area.containsPoint(point)) return null;

    // if you are between workspaces, you aren't hovering above one.
    if (x_local % (area.height + self.workspace_spacing) > area.height) return null;

    const workspace_idx = x_local / (area.height + self.workspace_spacing);

    if (workspace_idx >= self.workspaces.len) return null;
    return @intCast(workspace_idx);
}

// Changes workspaces to whichever workspace was clicked on.
pub fn click(self: *const Workspaces, point: Point, button: MouseButton) void {
    if (button != .left_click) return;

    if (self.pointToWorkspaceIndex(point)) |wksp_idx| {
        const wksp = self.workspaces.get(wksp_idx);
        WorkspaceState.setWorkspace(wksp.id) catch |err| {
            log.warn("Failed to set workspace with: {s}", .{@errorName(err)});
        };
    }
}

/// The arguments for creating a Workspaces widget.
pub const NewArgs = struct {
    /// The background color of a normal workspace (not hovered or active)
    background_color: Color,
    /// The text color of a normal workspace (not hovered or active)
    text_color: Color,

    /// the background color of whichever workspace is hovered by the cursor.
    hover_workspace_background: Color,
    /// the text color of whichever workspace is hovered by the cursor.
    hover_workspace_text: Color,

    /// the background color of the active workspace.
    active_workspace_background: Color,
    /// The text color of the active workspace.
    active_workspace_text: Color,

    /// The array of UTF8 characters, each one corresponding
    /// to a workspace what an ID of it's index + 1.
    /// (so the first glyph is workspace 1, the second 2, etc.)
    ///
    /// Any symbols above the `max_workspace_count` idx, will
    /// be ignored.
    workspaces_symbols: []const u8 = "ΑΒΓΔΕΖΗΘΙΚ", //ΛΜΝΞΟΠΡΣΤΥΦΧΨΩ",

    /// The spacing between workspaces in pixels
    workspace_spacing: u16,

    /// The general padding for each size.
    padding: u16,

    /// Overrides general padding the top side
    padding_north: ?u16 = null,
    /// Overrides general padding the bottom side
    padding_south: ?u16 = null,
    /// Overrides general padding the right side
    padding_east: ?u16 = null,
    /// Overrides general padding the left side
    padding_west: ?u16 = null,

    /// The area the widget will take up.
    area: Rect,
};

/// Allocates a new workspaces widget and initializes it.
/// Must call deinit on the returned widget to destroy.
pub fn new(allocator: Allocator, args: NewArgs) !*Widget {
    const workspaces = try allocator.create(Workspaces);

    workspaces.* = try init(args);

    return &workspaces.widget;
}

/// Initializes the workspaces widget.
/// Must call deinit to destroy.
pub fn init(args: NewArgs) !Workspaces {
    if (options.workspaces_provider == .none) return error.@"None Selected";

    assert(unicode.utf8ValidateSlice(args.workspaces_symbols));

    try workspace_state.init();

    // convert given string of workspaces into a decoded unicode array
    var symbols = WorkspaceSymbolArray{};
    var utf8_iter = unicode.Utf8Iterator{ .bytes = args.workspaces_symbols, .i = 0 };

    var loop_counter: usize = 0;
    while (utf8_iter.nextCodepoint()) |char| : (loop_counter += 1) {
        assert(loop_counter < max_workspace_count);
        symbols.append(char) catch {
            log.warn("Too many workspace symbols given, only the first {} will be used. Increase max_workspace_count", .{max_workspace_count});
            break;
        };
    }

    return .{
        .background_color = args.background_color,
        .text_color = args.text_color,

        .hover_workspace_background = args.hover_workspace_background,
        .hover_workspace_text = args.hover_workspace_text,

        .active_workspace = undefined,
        .active_workspace_background = args.active_workspace_background,
        .active_workspace_text = args.active_workspace_text,

        .workspaces = .{},
        .workspaces_symbols = symbols,

        .padding = Padding.from(args),

        .workspace_spacing = args.workspace_spacing,

        .widget = .{
            .vtable = Widget.generateVTable(Workspaces),
            .area = args.area,
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

const colors = @import("../colors.zig");
const Color = colors.Color;

const options = @import("options");

const std = @import("std");
const posix = std.posix;
const unicode = std.unicode;

const Allocator = std.mem.Allocator;
const BoundedArray = std.BoundedArray;
const assert = std.debug.assert;

const log = std.log.scoped(.Workspaces);
