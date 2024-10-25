//! This manages the FreeType library's context, including allocations it makes.
//!
//! TODO: Implement caching, and see if that is needed. (maybe behind compile option)
//!

pub const FreeTypeContext = @This();
pub var global: FreeTypeContext = undefined;

freetype_lib: freetype.FT_Library,
font_face: freetype.FT_Face,

cache: Cache,
allocator: Allocator,

internal: Internal,

pub const Internal = struct {
    freetype_allocator: freetype.FT_MemoryRec_,
    alloc_user: freetype_utils.AllocUser,

    fixed_buffer: if (options.freetype_allocator == .@"fixed-buffer") *FixedBufferAllocator else void,
};

pub const Cache = AutoHashMapUnmanaged(CacheKey, Glyph);
pub const CacheKey = struct {
    /// A unicode character
    char: u21,
    /// The pixel font size
    font_size: u32,
};

/// Stores a glyph, and it's bitmap (if needed);
/// the bitmap fields will be undefined if the load_mode is less than render.
pub const Glyph = struct {
    metrics: freetype.FT_Glyph_Metrics,

    advance_x: u31,

    bitmap_top: u31,
    bitmap_left: u31,

    bitmap_width: u31,
    bitmap_height: u31,
    bitmap_buffer: ?[]const u8,

    load_mode: LoadMode,

    pub fn from(allocator: Allocator, glyph: freetype.FT_GlyphSlot, load_mode: LoadMode) Glyph {
        const bitmap = glyph.*.bitmap;

        const bitmap_buffer = if (load_mode == .render) bitmap_buffer: {
            const bitmap_buffer = allocator.alloc(u8, bitmap.rows * bitmap.width) catch @panic("Out Of Memory");

            @memcpy(bitmap_buffer, bitmap.buffer[0 .. bitmap.rows * bitmap.width]);

            break :bitmap_buffer bitmap_buffer;
        } else null;

        return .{
            .metrics = glyph.*.metrics,
            .advance_x = @intCast(glyph.*.advance.x),
            .bitmap_top = @intCast(glyph.*.bitmap_top),
            .bitmap_left = @intCast(glyph.*.bitmap_left),
            .bitmap_width = @intCast(bitmap.width),
            .bitmap_height = @intCast(bitmap.rows),
            .bitmap_buffer = bitmap_buffer,
            .load_mode = load_mode,
        };
    }
};

pub fn init_global(parent_allocator: Allocator) Allocator.Error!void {
    const alloc = alloc: {
        const alloc = switch (options.freetype_allocator) {
            .c => std.heap.c_allocator,
            .zig => parent_allocator,
            .@"fixed-buffer" => fixed_buffer: {
                var fixed_buffer = try parent_allocator.create(FixedBufferAllocator);
                global.internal.fixed_buffer = fixed_buffer;

                fixed_buffer.* = FixedBufferAllocator.init(try parent_allocator.alloc(u8, options.freetype_fixed_allocator_len));

                break :fixed_buffer fixed_buffer.allocator();
            },
        };

        break :alloc alloc;
    };

    global.allocator = parent_allocator;
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

    global.cache = Cache{};
}

pub fn deinit(self: *FreeTypeContext) void {
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
    if (options.freetype_allocator == .@"fixed-buffer") {
        self.allocator.free(self.internal.fixed_buffer.buffer);
    }

    var cache_iter = self.cache.valueIterator();

    while (cache_iter.next()) |glyph| {
        if (glyph.bitmap_buffer) |buffer| {
            self.allocator.free(buffer);
        }
    }

    self.cache.deinit(self.internal.alloc_user.allocator);

    self.* = undefined;
}

//fn setFontSize(self: *const FreeTypeContext, output_context: *const DrawContext.OutputContext, font_size: u32) void {
//    // screen size in milimeters
//    const physical_height: u32 = output_context.physical_height;
//    const physical_width: u32 = output_context.physical_width;
//
//    // screen pixel size
//    const height: u32 = output_context.height;
//    const width: u32 = output_context.width;
//
//    assert(height > 0);
//    assert(width > 0);
//
//    // mm to inches, (mm * 5) / 127, convert physical from mm to inches, then take pixel and divide by physical.
//    const hori_dpi = (height * 127) / (physical_height * 5);
//    const vert_dpi = (width * 127) / (physical_width * 5);
//
//    const err = freetype.FT_Set_Char_Size(
//        self.font_face,
//        @intCast(font_size << 6), // multiply by 64 because they measure it in 1/64 points
//        0,
//        @intCast(hori_dpi),
//        @intCast(vert_dpi),
//    );
//    freetype_utils.errorAssert(err, "Failed to set font size", .{});
//}

/// Sets the current pixel font size of FreeType.
fn setFontPixelSize(self: *const FreeTypeContext, font_size: u32) void {
    assert(font_size > 0);

    const err = freetype.FT_Set_Pixel_Sizes(
        self.font_face,
        0,
        font_size,
    );
    freetype_utils.errorAssert(err, "Failed to set font size", .{});
}

pub const LoadMode = enum(u2) {
    /// Just load basic things
    default = 0,
    /// Compute the metrics of the glyph as well
    metrics,
    /// Render the glyph's bitmap
    render,
};

pub const MaximumFontSizeReturn = struct {
    font_size: u31,
    width: u31,
    height: u31,
};

/// Returns the largest font size specified glyph can be to fit in the area.
/// This loads the glyph twice, and does not cache the first load.
/// The second load is cached with `LoadMode.metrics`
pub fn maximumFontSize(self: *FreeTypeContext, char: u21, area: Rect) MaximumFontSizeReturn {
    const scale_initial = @min(area.width, area.height);
    const metrics_initial = self.loadCharNoCache(char, scale_initial, .metrics).metrics;

    const width_initial: u31 = @intCast(metrics_initial.width >> 6);
    const height_initial: u31 = @intCast(metrics_initial.height >> 6);

    log.debug("maximumFontSize :: area width: {}, height: {}", .{ area.width, area.height });
    log.debug("\tinitial width: {}, height: {}", .{ width_initial, height_initial });

    const width_scaling = area.width * area.width / width_initial;
    const height_scaling = area.height * area.height / height_initial;

    const scale_new = @min(width_scaling, height_scaling);

    const metrics_new = self.loadChar(char, scale_new, .metrics).metrics;

    const width_new: u31 = @intCast(metrics_new.width >> 6);
    const height_new: u31 = @intCast(metrics_new.height >> 6);

    log.debug("\tnew width: {}, height: {}", .{ width_new, height_new });

    assert(width_new <= area.width);
    assert(height_new <= area.height);

    return .{
        .font_size = scale_new,
        .width = width_new,
        .height = height_new,
    };
}

/// Returns a pointer to a `Glyph`. This pointer may be invalidated after another call to loadChar,
///     and should not be stored.
///
/// char_slice should be a single UTF8 Codepoint.
///
pub fn loadCharSlice(self: *FreeTypeContext, char_slice: []const u8, font_size: u32, load_mode: LoadMode) *Glyph {
    assert(char_slice.len > 0);

    if (unicode.utf8ByteSequenceLength(char_slice[0]) catch null) |len| {
        assert(char_slice.len == len);
    }

    const utf8_char = unicode.utf8Decode(char_slice) catch |err| utf8_char: {
        log.warn("\tFailed to decode character as UTF8 with: {s}", .{@errorName(err)});

        break :utf8_char 0;
    };

    return self.loadChar(utf8_char, font_size, load_mode);
}

/// Returns a pointer to a `Glyph`. This pointer may be invalidated after another call to loadChar,
///     and should not be stored.
///
pub fn loadChar(self: *FreeTypeContext, char: u21, font_size: u32, load_mode: LoadMode) *Glyph {
    // TODO: Implement cache clearing
    const cache_record = self.cache.getOrPut(
        self.allocator,
        .{
            .char = char,
            .font_size = font_size,
        },
    ) catch @panic("Out Of Memory");

    if (cache_record.found_existing) {
        if (@intFromEnum(load_mode) <= @intFromEnum(cache_record.value_ptr.load_mode)) {
            return cache_record.value_ptr;
        }
        //log.debug("Cached glyph had lower load_mode: '{s}', {s} vs {s}", .{ char_slice, @tagName(load_mode), @tagName(cache_hit.load_mode) });
    } else {
        //log.debug("Cache miss on glyph: '{s}' with size: {}", .{ char_slice, font_size });
    }

    cache_record.value_ptr.* = self.loadCharNoCache(char, font_size, load_mode);

    return cache_record.value_ptr;
}

pub fn loadCharNoCache(self: *FreeTypeContext, char: u21, font_size: u32, load_mode: LoadMode) Glyph {
    self.setFontPixelSize(font_size);

    const freetype_flags: i32 = switch (load_mode) {
        .default => freetype.FT_LOAD_DEFAULT,
        .metrics => freetype.FT_LOAD_COMPUTE_METRICS,
        .render => freetype.FT_LOAD_RENDER | freetype.FT_LOAD_COMPUTE_METRICS,
    };

    const err = freetype.FT_Load_Char(self.font_face, char, freetype_flags);

    if (freetype_utils.isErr(err)) {
        freetype_utils.errorPrint(err, "Failed to load Glyph with", .{});

        const err2 = freetype.FT_Load_Glyph(self.font_face, 0, freetype_flags);
        freetype_utils.errorAssert(err2, "Failed to load replacement glyph!", .{});
    }

    return Glyph.from(self.allocator, self.font_face.*.glyph, load_mode);
}

pub const DrawCharArgs = struct {
    draw_context: *const DrawContext,
    text_color: Color,

    /// The maximum area it can take up.
    area: Rect,

    /// Draw this character.
    char: u21,

    /// Used to debug
    outline: bool,

    /// At this font size.
    font_size: u32,

    /// How to align horizontally the glyph in the maximum area.
    hori_align: Align,
    /// How to align vertically the glyph in the maximum area.
    vert_align: Align,

    /// Which width scaling option to use.
    width: WidthOptions,

    pub const WidthOptions = union(enum) {
        /// Make the max glyph area a specific width.
        fixed: u31,
        /// Scale the glyph's advance width by a function.
        scaling: *const fn (u31) u31,
        /// just use the glyph's advance width
        advance,
    };
};

/// Draw the given character
/// Returns the width of the max area.
pub fn drawChar(freetype_context: *FreeTypeContext, args: DrawCharArgs) void {
    const glyph = freetype_context.loadChar(args.char, args.font_size, .render);

    const glyph_dims = Point{
        .x = glyph.bitmap_width,
        .y = glyph.bitmap_height,
    };

    const max_glyph_area = Rect{
        .x = args.area.x,
        .y = args.area.y,
        .height = args.area.height,
        .width = switch (args.width) {
            .advance => glyph.advance_x >> 6,
            .fixed => |fixed| fixed,
            .scaling => |scale_func| scale_func(glyph.advance_x >> 6),
        },
    };

    const glyph_area = max_glyph_area.alignWith(glyph_dims, args.hori_align, args.vert_align);

    const glyph_height: u31 = @intCast(glyph.metrics.height >> 6);
    const glyph_upper: u31 = @intCast(glyph.metrics.horiBearingY >> 6);

    const origin = Point{
        .x = glyph_area.x - glyph.bitmap_left,
        .y = glyph_area.y + glyph_area.height - glyph_height + glyph_upper,
    };

    args.draw_context.drawBitmap(.{
        .origin = origin,
        .text_color = args.text_color,
        .max_area = glyph_area,
        .glyph = glyph,
    });

    if (args.outline) {
        max_glyph_area.drawOutline(args.draw_context, colors.love);
        glyph_area.drawOutline(args.draw_context, colors.border);
    }
}

test global {
    try init_global(std.testing.allocator);
    defer global.deinit();
}

const DrawContext = @import("DrawContext.zig");
const Config = @import("Config.zig");

const drawing = @import("drawing.zig");
const Align = drawing.Align;
const Point = drawing.Point;
const Rect = drawing.Rect;

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
const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const BoundedArray = std.BoundedArray;

const runtime_safety = std.debug.runtime_safety;
const log = std.log.scoped(.FreeTypeContext);
