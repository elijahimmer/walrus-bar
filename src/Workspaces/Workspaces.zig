//! TODO: implement padding and workspace spacing.

pub const Workspaces = @This();

pub const Workspace = struct {
    area: Rect,
    id: WorkspaceID,
    char: u21,

    should_redraw: bool = true,
};
pub const WorkspacesArray = BoundedArray(Workspace, max_workspace_count);

const workspace_state = &WorkspaceState.global;

background_color: Color,
text_color: Color,

/// The ID of the workspace the cursor is over.
/// Reset this every time the workspaces array is changed.
hover_workspace_idx: ?WorkspaceIndex = null,
hover_workspace_drawn: ?WorkspaceIndex = null,
hover_workspace_background: Color,
hover_workspace_text: Color,

active_workspace_background: Color,
active_workspace_text: Color,
/// tells the widget to fill it's entire background not
/// taken up by a workspace. Used when removing a workspace to get
/// rid of the left-behinds.
fill_background: bool = false,

widget: Widget,

active_workspace: WorkspaceID,
workspaces: WorkspacesArray,
workspaces_symbols: []const u8,

pub fn getWidth(self: *Workspaces) u31 {
    return self.widget.area.height * max_workspace_count;
}

pub fn setArea(self: *Workspaces, area: Rect) void {
    // TODO: Make this have a dynamic max_workspace_count for the size it can hold.
    assert(area.height * max_workspace_count <= area.width);

    self.widget.area = area;
    self.widget.full_redraw = true;
}

pub inline fn fontScalingFactor(height: u31) u31 {
    return height * 3 / 4;
}

pub fn drawWidget(widget: *Widget, draw_context: *DrawContext) anyerror!void {
    const self: *Workspaces = @fieldParentPtr("widget", widget);

    try self.updateState();

    const full_redraw = draw_context.full_redraw or self.widget.full_redraw;

    if (full_redraw) {
        self.widget.area.drawArea(draw_context, self.background_color);
    }

    const font_size = fontScalingFactor(self.widget.area.height);

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
            self.workspaces.len * self.widget.area.height
        else
            0;

        var area = self.widget.area;

        assert(start < area.width);

        area.x += start;
        area.width -= start;

        area.drawArea(draw_context, self.background_color);
        draw_context.damage(area);
    }
}

fn getWorkspaceSymbol(self: *const Workspaces, idx: WorkspaceID) u21 {
    var count: WorkspaceIndex = 1;

    var symbol_iter = unicode.Utf8Iterator{ .bytes = self.workspaces_symbols, .i = 0 };

    while (symbol_iter.nextCodepoint()) |code_point| {
        if (count == idx) return code_point;

        count += 1;
    }

    return '?'; // unknown workspace
}

fn updateState(self: *Workspaces) !void {
    workspace_state.rwlock.lockShared();
    defer workspace_state.rwlock.unlockShared();

    switch (std.math.order(workspace_state.workspaces.len, self.workspaces.len)) {
        // add more
        .gt => {
            const area = self.widget.area;
            var workspace_area = Rect{
                .x = area.x + self.workspaces.len * area.height,
                .y = area.y,
                .width = area.height, // set width to height
                .height = area.height,
            };

            for (0..workspace_state.workspaces.len - self.workspaces.len) |_| {
                self.widget.area.assertContains(workspace_area);

                self.workspaces.appendAssumeCapacity(.{
                    .area = workspace_area,
                    .char = 0,
                    .id = undefined,
                });

                workspace_area.x += area.height;
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

fn pointToWorkspaceIndex(self: *Workspaces, point: Point) ?WorkspaceIndex {
    const x_local = point.x - self.widget.area.x;
    const y_local = point.y - self.widget.area.y;
    _ = y_local;

    // TODO: Update when add padding, so only hover when over.

    const workspace_idx = x_local / self.widget.area.height;

    if (workspace_idx >= self.workspaces.len) return null;
    return @intCast(workspace_idx);
}

pub fn clickWidget(widget: *Widget, point: Point, button: MouseButton) void {
    const self: *Workspaces = @fieldParentPtr("widget", widget);

    if (button != .left_click) return;

    if (self.pointToWorkspaceIndex(point)) |wksp_idx| {
        const wksp = self.workspaces.get(wksp_idx);
        WorkspaceState.setWorkspace(wksp.id) catch |err| {
            log.warn("Failed to set workspace with: {s}", .{@errorName(err)});
        };
    }
}

pub const NewArgs = struct {
    background_color: Color,
    text_color: Color,

    hover_workspace_background: Color,
    hover_workspace_text: Color,

    active_workspace_background: Color,
    active_workspace_text: Color,

    workspaces_symbols: []const u8 = "ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ",

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

    return .{
        .background_color = args.background_color,
        .text_color = args.text_color,

        .hover_workspace_background = args.hover_workspace_background,
        .hover_workspace_text = args.hover_workspace_text,

        .active_workspace = undefined,
        .active_workspace_background = args.active_workspace_background,
        .active_workspace_text = args.active_workspace_text,

        .workspaces = .{},
        .workspaces_symbols = args.workspaces_symbols,

        .widget = .{
            .area = args.area,
            .vtable = &Widget.generateVTable(Workspaces).vtable,
        },
    };
}

pub fn deinitWidget(widget: *Widget, allocator: Allocator) void {
    const self: *Workspaces = @fieldParentPtr("widget", widget);

    self.deinit();
    allocator.destroy(self);
}

pub fn deinit(self: *Workspaces) void {
    workspace_state.deinit();
    self.* = undefined;
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
