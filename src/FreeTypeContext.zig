//! This manages the FreeType library's context, including allocations it makes.
//!
//! TODO: Implement caching, and see if that is needed. (maybe behind compile option)
//!

pub const FreeTypeContext = @This();
pub var global: FreeTypeContext = undefined;

freetype_lib: freetype.FT_Library,
font_face: freetype.FT_Face,

internal: Internal,

pub const Internal = struct {
    freetype_allocator: freetype.FT_MemoryRec_,
    parent_allocator: Allocator,
    alloc_user: freetype_utils.AllocUser,
};

pub fn init_global(parent_allocator: Allocator) Allocator.Error!void {
    global.internal.parent_allocator = parent_allocator;

    const alloc = alloc: {
        const alloc = switch (options.freetype_allocator) {
            .c => std.heap.c_allocator,
            .zig => parent_allocator,
        };

        break :alloc alloc;
    };

    global.internal.alloc_user = try freetype_utils.AllocUser.init(alloc);
    global.internal.freetype_allocator = freetype.FT_MemoryRec_{
        .user = &global.internal.alloc_user,
        .alloc = freetype_utils.alloc,
        .free = freetype_utils.free,
        .realloc = freetype_utils.realloc,
    };

    {
        const err = freetype.FT_New_Library(&global.internal.freetype_allocator, &global.freetype_lib);
        freetype_utils.errorAssert(err, "Failed to initilize freetype", .{});
    }
    errdefer freetype.FT_Done_Library(&global.freetype_lib);

    // TODO: Maybe customize modules to only what is needed.
    freetype.FT_Add_Default_Modules(global.freetype_lib);
    freetype.FT_Set_Default_Properties(global.freetype_lib);

    log.info("freetype version: {}.{}.{}", .{ freetype.FREETYPE_MAJOR, freetype.FREETYPE_MINOR, freetype.FREETYPE_PATCH });

    // TODO: allow for runtime custom font
    {
        const font_data = font.font_data;
        const err = freetype.FT_New_Memory_Face(global.freetype_lib, font_data.ptr, font_data.len, 0, &global.font_face);
        freetype_utils.errorAssert(err, "Failed to initilize font", .{});
    }
    errdefer freetype.FT_Done_Face(&global.font_face);

    const font_family = if (global.font_face.*.family_name) |family| mem.span(@as([*:0]const u8, @ptrCast(family))) else "none";
    const font_style = if (global.font_face.*.style_name) |style| mem.span(@as([*:0]const u8, @ptrCast(style))) else "none";

    assert(global.font_face.*.face_flags & freetype.FT_FACE_FLAG_HORIZONTAL != 0); // make sure it has horizontal spacing metrics

    log.info("font family: {s}, style: {s}", .{ font_family, font_style });

    { // set font encoding
        const err = freetype.FT_Select_Charmap(global.font_face, freetype.FT_ENCODING_UNICODE);
        freetype_utils.errorAssert(err, "Failed to set charmap to unicode", .{});
    }
}

pub fn deinit_global() void {
    {
        const err = freetype.FT_Done_Face(global.font_face);
        freetype_utils.errorPrint(err, "Failed to free FreeType Font", .{});
    }
    {
        const err = freetype.FT_Done_Library(global.freetype_lib);
        freetype_utils.errorPrint(err, "Failed to free FreeType Library", .{});
    }

    for (global.internal.alloc_user.alloc_list.items) |allocation| {
        log.warn("FreeType failed to deallocate {} bytes at 0x{x}", .{ allocation.len, @intFromPtr(allocation.ptr) });
        global.internal.alloc_user.allocator.free(allocation);
    }

    global.internal.alloc_user.alloc_list.deinit(global.internal.alloc_user.allocator);

    global = undefined;
}

pub fn setFontSize(self: *const FreeTypeContext, output_context: *const DrawContext.OutputContext, font_size: u32) void {
    // screen size in milimeters
    const physical_height: u32 = output_context.physical_height;
    const physical_width: u32 = output_context.physical_width;

    // screen pixel size
    const height: u32 = output_context.height;
    const width: u32 = output_context.width;

    assert(physical_height > 0);
    assert(physical_width > 0);
    assert(height > 0);
    assert(width > 0);

    // mm to inches, (mm * 5) / 127, convert physical from mm to inches, then take pixel and divide by physical.
    const hori_dpi = (height * 127) / (physical_height * 5);
    const vert_dpi = (width * 127) / (physical_width * 5);

    const err = freetype.FT_Set_Char_Size(
        self.font_face,
        @intCast(font_size << 6), // multiply by 64 because they measure it in 1/64 points
        0,
        @intCast(hori_dpi),
        @intCast(vert_dpi),
    );
    freetype_utils.errorAssert(err, "Failed to set font size", .{});
}

// TODO: Fix this.
pub fn setFontPixelSize(self: *const FreeTypeContext, output_context: *const DrawContext.OutputContext, width: u32, height: u32) void {
    // screen size in milimeters
    const physical_height: u32 = output_context.physical_height;
    const physical_width: u32 = output_context.physical_width;

    assert(physical_height > 0);
    assert(physical_width > 0);
    assert(height > 0 or width > 0);

    // mm to inches, (mm * 5) / 127, convert physical from mm to inches, then take pixel and divide by physical.
    const hori_dpi = (height * 127) / (physical_height * 5);
    const vert_dpi = (width * 127) / (physical_width * 5);

    var size_req = freetype.FT_Size_RequestRec{
        .type = freetype.FT_SIZE_REQUEST_TYPE_REAL_DIM,
        .width = width << 6,
        .height = height << 6,
        .horiResolution = hori_dpi,
        .vertResolution = vert_dpi,
    };

    const err = freetype.FT_Request_Size(
        self.font_face,
        &size_req,
    );
    freetype_utils.errorAssert(err, "Failed to set font size", .{});
}

pub const loadCharFlags = enum {
    default,
    render,
};

/// char_slice should be a single UTF8 Codepoint.
pub fn loadChar(self: *const FreeTypeContext, char_slice: []const u8, flag: loadCharFlags) freetype.FT_GlyphSlot {
    assert(char_slice.len > 0);

    const utf8_char = unicode.utf8Decode(char_slice) catch |err| utf8_char: {
        log.warn("\tFailed to decode character as UTF8 with: {s}", .{@errorName(err)});

        break :utf8_char 0;
    };

    const freetype_flags: i32 = switch (flag) {
        .default => freetype.FT_LOAD_DEFAULT,
        .render => freetype.FT_LOAD_RENDER,
    };

    const err = freetype.FT_Load_Char(self.font_face, utf8_char, freetype_flags);

    if (freetype_utils.isErr(err)) {
        freetype_utils.errorPrint(err, "Failed to load Glyph with", .{});

        const err2 = freetype.FT_Load_Glyph(self.font_face, 0, freetype_flags);
        freetype_utils.errorAssert(err2, "Failed to load replacement glyph!", .{});
    }

    return self.font_face.*.glyph;
}

/// Draws the bitmap of the loaded character with
pub fn drawChar(self: *const FreeTypeContext, draw_context: *const DrawContext, origin: Point, color: Color) void {
    _ = self;
    _ = draw_context;
    _ = origin;
    _ = color;
}

test global {
    try init_global(std.testing.allocator);
    defer deinit_global();

    global.setFontSize(&.{
        .output = undefined,
        .id = undefined,

        .physical_width = 800,
        .physical_height = 330,

        .width = 3440,
        .height = 1440,
    }, 50 * 64);
}

const DrawContext = @import("DrawContext.zig");
const Config = @import("Config.zig");

const drawing = @import("drawing.zig");
const Point = drawing.Point;

const colors = @import("colors.zig");
const Color = colors.Color;

const freetype_utils = @import("freetype_utils.zig");
const options = @import("options");
const font = @import("font");

pub const freetype = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftsystem.h");
    @cInclude("freetype/ftmodapi.h");
});
const FT_Memory = freetype.FT_Memory;

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const unicode = std.unicode;

const Allocator = mem.Allocator;

const log = std.log.scoped(.FreeTypeContext);
