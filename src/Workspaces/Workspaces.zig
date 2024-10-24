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

fn setAreaWidget(widget: *Widget, area: Rect) void {
    const self: *Workspaces = @fieldParentPtr("widget", widget);
    self.setArea(area);
}

pub fn setArea(self: *Workspaces, area: Rect) void {
    // TODO: Maybe make this not crash if it is not wide enough
    // Should always be wide enough
    assert(area.height * max_workspace_count <= area.width);

    self.widget.area = area;
    self.widget.full_redraw = true;
}

fn drawWidget(widget: *Widget, draw_context: *DrawContext) anyerror!void {
    const self: *Workspaces = @fieldParentPtr("widget", widget);

    try self.draw(draw_context);
}

pub inline fn fontScalingFactor(height: u31) u31 {
    return height * 75 / 100;
}

pub fn draw(self: *Workspaces, draw_context: *DrawContext) !void {
    try self.updateState();

    const full_redraw = self.widget.full_redraw;

    if (full_redraw) {
        log.debug("full redraw", .{});

        self.widget.area.drawArea(draw_context, self.background_color);
    }

    const font_size = fontScalingFactor(self.widget.area.height);

    for (self.workspaces.slice()) |*wksp| {
        if (full_redraw or wksp.should_redraw) {
            const background_color = if (wksp.id == self.active_workspace)
                self.active_workspace_background
            else
                self.background_color;

            wksp.area.drawArea(draw_context, background_color);

            freetype_context.drawChar(.{
                .draw_context = draw_context,

                .text_color = self.text_color,

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
            wksp.should_redraw = false;
        }
    }

    // fill in the left-behinds
    if (self.fill_background and !self.widget.full_redraw) {
        var area = self.widget.area;

        const start = if (self.workspaces.len > 0)
            self.workspaces.len * area.height
        else
            0;

        assert(start < area.width);

        area.x += start;
        area.width -= start;

        area.drawArea(draw_context, self.background_color);
        draw_context.damage(area);
    }

    self.fill_background = false;
    self.widget.full_redraw = false;
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

/// TODO: Gracefully handle too many workspaces
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

        if (wk_id == workspace_state.active_workspace and wk_id != self.active_workspace) {
            wksp.should_redraw = true;
        } else if (wk_id == self.active_workspace and wk_id != workspace_state.active_workspace) {
            wksp.should_redraw = true;
        }

        if (wksp.char != wk_symbol) {
            wksp.char = wk_symbol;
            wksp.should_redraw = true;
        }
    }

    self.active_workspace = workspace_state.active_workspace;
}

pub const NewArgs = struct {
    background_color: Color,
    text_color: Color,

    active_workspace_background: Color,
    active_workspace_text: Color,

    workspaces_symbols: []const u8 = "ΑΒΓΔΕΖΗΘΙΚ",

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

        .active_workspace_background = args.active_workspace_background,
        .active_workspace_text = args.active_workspace_text,

        .active_workspace = undefined,
        .workspaces = .{},
        .workspaces_symbols = args.workspaces_symbols,

        .widget = .{
            .area = args.area,
            .vtable = &.{
                .draw = &drawWidget,
                .setArea = &setAreaWidget,
                .deinit = &deinitWidget,
            },
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

const WorkspaceState = @import("WorkspaceState.zig");
const WorkspaceIndex = WorkspaceState.WorkspaceIndex;
const WorkspaceID = WorkspaceState.WorkspaceID;
const max_workspace_count = WorkspaceState.max_workspace_count;

const DrawContext = @import("../DrawContext.zig");

const FreeTypeContext = @import("../FreeTypeContext.zig");
const freetype_context = &FreeTypeContext.global;

const drawing = @import("../drawing.zig");
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
