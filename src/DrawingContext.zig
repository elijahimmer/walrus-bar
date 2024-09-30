pub const DrawingContext = @This();

screen: drawing.Screen,
freetype_lib: freetype.FT_Library,
font_face: freetype.FT_Face,

internal: Internal,

pub const Internal = struct {
    freetype_allocator: freetype.FT_MemoryRec_,
    parent_allocator: Allocator,
    alloc_user: freetype_utils.AllocUser,
};

pub const InitArgs = struct {
    parent_allocator: Allocator,
    output_context: *const OutputContext,
    screen: *const Screen,
};

pub fn init(args: InitArgs) Allocator.Error!*DrawingContext {
    var ctx = try args.parent_allocator.create(DrawingContext);
    ctx.* = undefined;

    errdefer args.parent_allocator.destroy(ctx);
    ctx.internal.parent_allocator = args.parent_allocator;

    const alloc = alloc: {
        const alloc = switch (options.freetype_allocator) {
            .c => std.heap.c_allocator,
            .zig => args.parent_allocator,
        };

        break :alloc alloc;
    };

    ctx.internal.alloc_user = try freetype_utils.AllocUser.init(alloc);
    ctx.internal.freetype_allocator = freetype.FT_MemoryRec_{
        .user = &ctx.internal.alloc_user,
        .alloc = freetype_utils.alloc,
        .free = freetype_utils.free,
        .realloc = freetype_utils.realloc,
    };

    // // standard setup without a custom allocator
    //var err = freetype.FT_Init_FreeType(&ctx.freetype_lib);
    //errdefer freetype.FT_Done_FreeType(&ctx.freetype_lib);

    {
        const err = freetype.FT_New_Library(&ctx.internal.freetype_allocator, &ctx.freetype_lib);
        freetype_utils.errorAssert(err, "Failed to initilize freetype", .{});
    }
    errdefer freetype.FT_Done_Library(&ctx.freetype_lib);

    // TODO: Maybe customize modules to only what is needed.
    freetype.FT_Add_Default_Modules(ctx.freetype_lib);
    freetype.FT_Set_Default_Properties(ctx.freetype_lib);

    log.info("freetype version: {}.{}.{}", .{ freetype.FREETYPE_MAJOR, freetype.FREETYPE_MINOR, freetype.FREETYPE_PATCH });

    // TODO: allow for runtime custom font
    {
        const font_data = options.font_data;
        const err = freetype.FT_New_Memory_Face(ctx.freetype_lib, font_data.ptr, font_data.len, 0, &ctx.font_face);
        freetype_utils.errorAssert(err, "Failed to initilize font", .{});
    }
    errdefer freetype.FT_Done_Face(&ctx.font_face);

    const font_family = if (ctx.font_face.*.family_name) |family| mem.span(@as([*:0]const u8, @ptrCast(family))) else "none";
    const font_style = if (ctx.font_face.*.style_name) |style| mem.span(@as([*:0]const u8, @ptrCast(style))) else "none";

    assert(ctx.font_face.*.face_flags & freetype.FT_FACE_FLAG_HORIZONTAL != 0); // make sure it has horizontal spacing metrics

    log.info("font family: {s}, style: {s}", .{ font_family, font_style });

    { // set font encoding
        const err = freetype.FT_Select_Charmap(ctx.font_face, freetype.FT_ENCODING_UNICODE);
        freetype_utils.errorAssert(err, "Failed to set charmap to unicode", .{});
    }

    { // set font size
        // screen size in milimeters
        const physical_height = args.output_context.physical_height;
        const physical_width = args.output_context.physical_width;

        // screen pixel size
        const height = args.output_context.height;
        const width = args.output_context.width;

        // mm to inches, (mm * 5) / 127
        const horz_dpi = if (physical_height != null and height != null and height.? > 0)
            (@as(u64, @intCast(height.?)) * 127) / (@as(u64, @intCast(physical_height.?)) * 5)
        else
            0;

        const vert_dpi = if (physical_width != null and width != null and width.? > 0)
            (@as(u64, @intCast(width.?)) * 127) / (@as(u64, @intCast(physical_width.?)) * 5)
        else
            0;

        const err = freetype.FT_Set_Char_Size(
            ctx.font_face,
            @intCast(config.font_size << 6), // multiply by 64 because they measure it in 1/64 points
            0,
            @intCast(horz_dpi),
            @intCast(vert_dpi),
        );
        freetype_utils.errorAssert(err, "Failed to set font size", .{});
    }

    return ctx;
}

pub fn deinit(self: *DrawingContext) void {
    {
        const err = freetype.FT_Done_Face(self.font_face);
        freetype_utils.errorPrint(err, "Failed to free FreeType Font", .{});
    }
    {
        const err = freetype.FT_Done_Library(self.freetype_lib);
        freetype_utils.errorPrint(err, "Failed to free FreeType Library", .{});
    }

    for (self.internal.alloc_user.alloc_list.items) |allocation| {
        log.warn("FreeType failed to deallocate {} bytes at 0x{x}", .{ allocation.len, @intFromPtr(allocation.ptr) });
        self.internal.alloc_user.allocator.free(allocation);
    }

    self.internal.alloc_user.alloc_list.deinit(self.internal.alloc_user.allocator);

    self.internal.parent_allocator.destroy(self);
}

const OutputContext = @import("main.zig").OutputContext;
const config = &@import("Config.zig").config;

const drawing = @import("drawing.zig");
const Screen = drawing.Screen;
const freetype_utils = @import("freetype_utils.zig");
const options = @import("options");

const freetype = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftsystem.h");
    @cInclude("freetype/ftmodapi.h");
});
const FT_Memory = freetype.FT_Memory;

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = mem.Allocator;

const log = std.log.scoped(.DrawingContext);
