//! This manages the FreeType library's context, including allocations it makes.
//!
//! TODO: Implement glyph outline drawing
//!

pub const FreeTypeContext = @This();
pub var global: FreeTypeContext = undefined;

freetype_lib: freetype.FT_Library,
font_face: freetype.FT_Face,
font_file: ?fs.File = null,
font_data: ?[]align(mem.page_size) const u8 = null,

cache: Cache,
allocator: Allocator,

cache_allocator_internal: FixedBufferAllocator,
cache_allocator_buffer: [options.freetype_cache_size]u8,

internal: Internal,

// Stores the internal FreeType allocation stuff.
pub const Internal = struct {
    freetype_allocator: freetype.FT_MemoryRec_,
    alloc_user: freetype_utils.AllocUser,
};

pub const max_cache_entries = options.freetype_cache_size / @sizeOf(Glyph);

comptime {
    if (max_cache_entries < 50) {
        @compileError("Choosen freetype-cache-size is too small and will be inefficient");
    }
    if (max_cache_entries > 5000) {
        @compileError("Choosen freetype-cache-size is too large and will be wasteful");
    }
}

pub const Cache = AutoArrayHashMap(CacheKey, Glyph);

pub const CacheKey = struct {
    /// A unicode character
    char: u21,
    /// The pixel font size
    font_size: Size,
    /// The glyph's transform
    transform: Transform,
};

/// Stores a glyph, and it's bitmap (if needed);
/// the bitmap fields will be undefined if the load_mode is less than render.
pub const Glyph = struct {
    time: i64,

    /// Metrics are invalid if a Transform is used.
    metrics: ?freetype.FT_Glyph_Metrics,

    advance_x: Size,

    bitmap_top: i32,
    bitmap_left: i32,

    bitmap_width: Size,
    bitmap_height: Size,
    bitmap_buffer: ?[]const u8,

    load_mode: LoadMode,

    transformed: bool,

    pub fn from(allocator: Allocator, glyph: freetype.FT_GlyphSlot, load_mode: LoadMode, transform: Transform) Glyph {
        const bitmap = glyph.*.bitmap;
        // TODO: When transformed to the left, the glyph's area is completely out of the box.

        const transformed = !transform.isIdentity();

        // change dimensions if it is rotated right or left.
        const bitmap_width: Size = @intCast(bitmap.width);
        const bitmap_height: Size = @intCast(bitmap.rows);
        const bitmap_top: SizeSigned = glyph.*.bitmap_top;
        const bitmap_left: SizeSigned = glyph.*.bitmap_left;

        const bitmap_buffer = if (load_mode == .render) bitmap_buffer: {
            const bitmap_buffer = allocator.alloc(u8, bitmap_height * bitmap_width) catch @panic("Out Of Memory");
            @memcpy(bitmap_buffer, bitmap.buffer[0 .. bitmap_height * bitmap_width]);

            break :bitmap_buffer bitmap_buffer;
        } else null;

        return .{
            .time = std.time.milliTimestamp(),
            .metrics = if (transformed) null else glyph.*.metrics,
            // TODO: Find out how to do transform for advance width, bitmap top, and bitmap left
            .advance_x = @intCast(glyph.*.advance.x),
            .bitmap_top = bitmap_top,
            .bitmap_left = bitmap_left,
            .bitmap_width = bitmap_width,
            .bitmap_height = bitmap_height,
            .bitmap_buffer = bitmap_buffer,
            .load_mode = load_mode,
            .transformed = transformed,
        };
    }

    pub fn deinit(self: *Glyph, allocator: Allocator) void {
        if (self.bitmap_buffer) |bitmap_buffer| {
            allocator.free(bitmap_buffer);
        }
        self.* = undefined;
    }
};

pub fn init_global(parent_allocator: Allocator, font_path: ?Path) Allocator.Error!void {
    global.cache_allocator_buffer = undefined;
    global.cache_allocator_internal = FixedBufferAllocator.init(&global.cache_allocator_buffer);
    global.cache = Cache.init(global.cache_allocator_internal.allocator());

    const alloc = alloc: {
        const alloc = switch (options.freetype_allocator) {
            .c => std.heap.c_allocator,
            .zig => parent_allocator,
        };

        break :alloc alloc;
    };

    global.font_file = null;
    global.font_data = null;
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
        if (font_path) |fp| specified_font: {
            assert(fs.path.isAbsolute(fp.constSlice()));
            const font_data = openFontFile(fp.constSlice()) catch break :specified_font;

            {
                const err = freetype.FT_New_Memory_Face(global.freetype_lib, font_data.ptr, @intCast(font_data.len), 0, &global.font_face);
                if (freetype_utils.isErr(err)) {
                    freetype_utils.errorPrint(err, "Failed to initialize specified font, resorting to backup", .{});
                    break :specified_font;
                }
            }

            if (global.font_face.*.face_flags & freetype.FT_FACE_FLAG_HORIZONTAL == 0) {
                log.warn("Provided font has no horizontal metrics!", .{});
                const err = freetype.FT_Done_Face(global.font_face);
                if (freetype_utils.isErr(err)) {
                    freetype_utils.errorPrint(err, "Failed to de-initialize the provided font!", .{});
                }

                break :specified_font;
            }
        }

        const err = freetype.FT_New_Memory_Face(global.freetype_lib, font.font_data.ptr, font.font_data.len, 0, &global.font_face);
        freetype_utils.errorAssert(err, "Failed to initilize font", .{});
    }

    const has_font = global.font_data != null and global.font_file != null;
    const no_font = global.font_data == null and global.font_file == null;
    assert(has_font or no_font);

    errdefer {
        if (has_font) {
            posix.munmap(global.font_data.?);
            global.font_file.?.close();
        }
        freetype.FT_Done_Face(&global.font_face);
    }

    const font_family = if (global.font_face.*.family_name) |family| mem.span(@as([*:0]const u8, @ptrCast(family))) else "none";
    const font_style = if (global.font_face.*.style_name) |style| mem.span(@as([*:0]const u8, @ptrCast(style))) else "none";

    assert(global.font_face.*.face_flags & freetype.FT_FACE_FLAG_HORIZONTAL != 0); // make sure it has horizontal spacing metrics

    log.info("font family: {s}, style: {s}", .{ font_family, font_style });

    { // set font encoding
        const err = freetype.FT_Select_Charmap(global.font_face, freetype.FT_ENCODING_UNICODE);
        freetype_utils.errorAssert(err, "Failed to set charmap to unicode", .{});
    }
}

pub fn openFontFile(path: []const u8) ![]const u8 {
    assert(fs.path.isAbsolute(path));
    defer {
        const has_font = global.font_data != null and global.font_file != null;
        const no_font = global.font_data == null and global.font_file == null;
        assert(has_font or no_font);
    }

    const font_file = fs.openFileAbsolute(path, .{}) catch |err| {
        log.warn("Failed to open font path: '{s}' with error: {s}", .{ path, @errorName(err) });
        return err;
    };
    errdefer font_file.close();

    const file_metadata = font_file.metadata() catch |err| {
        log.warn("Failed get metadata of font file: '{s}' with error: {s}", .{ path, @errorName(err) });
        return err;
    };

    if (file_metadata.kind() != .file) {
        log.warn("Font file given isn't a file, it's a '{s}'", .{@tagName(file_metadata.kind())});
        return error.@"Not a File";
    }

    const font_data = posix.mmap(null, file_metadata.size(), posix.PROT.READ, .{ .TYPE = .SHARED }, font_file.handle, 0) catch |err| {
        log.warn("Failed mmap to open font file: '{s}' with error: {s}", .{ path, @errorName(err) });
        return err;
    };
    errdefer posix.munmap(font_data);

    global.font_data = font_data;
    global.font_file = font_file;

    return font_data;
}

pub fn deinit(self: *FreeTypeContext) void {
    {
        const err = freetype.FT_Done_Face(self.font_face);
        freetype_utils.errorPrint(err, "Failed to free FreeType Font", .{});
    }
    const has_font = self.font_data != null and self.font_file != null;
    const no_font = self.font_data == null and self.font_file == null;
    assert(has_font or no_font);

    if (has_font) {
        posix.munmap(self.font_data.?);
        self.font_file.?.close();
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

    var cache_iter = self.cache.iterator();

    var loop_counter: usize = 0;
    while (cache_iter.next()) |entry| : (loop_counter += 1) {
        assert(loop_counter < max_cache_entries);
        entry.value_ptr.deinit(self.allocator);
    }

    self.cache.deinit();

    self.* = undefined;
}

//fn setFontSize(self: *const FreeTypeContext, output_context: *const DrawContext.OutputContext, font_size: Size) void {
//    // screen size in milimeters
//    const physical_height: Size = output_context.physical_height;
//    const physical_width: Size = output_context.physical_width;
//
//    // screen pixel size
//    const height: Size = output_context.height;
//    const width: Size = output_context.width;
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
fn setFontPixelSize(self: *const FreeTypeContext, font_size: Size) void {
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

pub const MaximumFontSizeArgs = struct {
    char: u21,
    area: Rect,
    transform: Transform,

    /// Applies to new scale to downscale if wanted.
    scaling_fn: ?*const fn (Size) Size,
};

pub const MaximumFontSizeReturn = struct {
    font_size: Size,
    width: Size,
    height: Size,
};

/// Returns the largest font size specified glyph can be to fit in the area.
/// This loads the glyph twice, and does not cache the first load.
/// The second load is cached with `LoadMode.metrics`
pub fn maximumFontSize(self: *FreeTypeContext, args: MaximumFontSizeArgs) MaximumFontSizeReturn {
    const area = args.area;
    const scale_initial = @min(area.width, area.height);
    const width_initial: Size, const height_initial: Size = if (args.transform.isIdentity()) initial: {
        const metrics_initial = self.loadCharNoCache(args.char, .{
            .font_size = scale_initial,
            .load_mode = .metrics,
            .transform = args.transform,
        }).metrics.?;

        break :initial .{
            @intCast(metrics_initial.width >> 6),
            @intCast(metrics_initial.height >> 6),
        };
    } else initial: {
        var glyph_initial = self.loadCharNoCache(args.char, .{
            .font_size = scale_initial,
            .load_mode = .render,
            .transform = args.transform,
        });
        defer glyph_initial.deinit(self.allocator);

        break :initial .{
            glyph_initial.bitmap_width,
            glyph_initial.bitmap_height,
        };
    };

    log.debug("maximumFontSize :: area width: {}, height: {}", .{ area.width, area.height });
    log.debug("\tinitial width: {}, height: {}", .{ width_initial, height_initial });

    const width_scaling = @as(u32, area.width) * area.width / width_initial;
    const height_scaling = @as(u32, area.height) * area.height / height_initial;

    const scaling: Size = @intCast(@min(width_scaling, height_scaling));

    const scale_new = if (args.scaling_fn) |scaling_fn| scaling_fn(scaling) else scaling;

    const width_new: Size, const height_new: Size = if (args.transform.isIdentity()) new: {
        const metrics_initial = self.loadCharNoCache(args.char, .{
            .font_size = scale_new,
            .load_mode = .metrics,
            .transform = args.transform,
        }).metrics.?;

        break :new .{
            @intCast(metrics_initial.width >> 6),
            @intCast(metrics_initial.height >> 6),
        };
    } else new: {
        var glyph_new = self.loadCharNoCache(args.char, .{
            .font_size = scale_initial,
            .load_mode = .render,
            .transform = args.transform,
        });
        defer glyph_new.deinit(self.allocator);

        break :new .{
            glyph_new.bitmap_width,
            glyph_new.bitmap_height,
        };
    };

    return .{
        .font_size = scale_new,
        .width = width_new,
        .height = height_new,
    };
}

pub const LoadCharOptions = struct {
    load_mode: LoadMode,
    transform: Transform,
    //rotation: Rotation,
    font_size: Size,
};

/// Returns a pointer to a `Glyph`. This pointer may be invalidated after another call to loadChar,
///     and should not be stored.
///
/// char_slice should be a single UTF8 Codepoint.
///
pub fn loadCharSlice(self: *FreeTypeContext, char_slice: []const u8, args: LoadCharOptions) *const Glyph {
    assert(char_slice.len > 0);

    const utf8_char = unicode.utf8Decode(char_slice) catch |err| utf8_char: {
        log.warn("\tFailed to decode character as UTF8 with: {s}", .{@errorName(err)});

        break :utf8_char 0;
    };

    return self.loadChar(utf8_char, args);
}

/// Returns a pointer to a `Glyph`. This pointer may be invalidated after another call to loadChar,
///     and should not be stored.
///
/// Asserts the character isn't '0' which means unknown.
///
pub fn loadChar(self: *FreeTypeContext, char: u21, args: LoadCharOptions) *const Glyph {
    assert(char != 0);
    const cache_key = CacheKey{
        .char = char,
        .font_size = args.font_size,
        .transform = args.transform,
    };
    const cache_record = self.cache.getOrPut(cache_key) catch cache_record: {
        self.cleanCache();
        break :cache_record self.cache.getOrPut(cache_key) catch unreachable;
    };

    // get char slice for debugging
    var char_buffer: [4]u8 = undefined;

    const bytes = unicode.utf8Encode(char, &char_buffer) catch |err| switch (err) {
        error.CodepointTooLarge, error.Utf8CannotEncodeSurrogateHalf => unreachable,
    };

    assert(bytes != 0);

    const char_slice = char_buffer[0..bytes];

    if (cache_record.found_existing) {
        if (@intFromEnum(args.load_mode) <= @intFromEnum(cache_record.value_ptr.load_mode)) {
            cache_log.debug("Cached glyph cache hit: '{any}' '{s}', {s} -> {s}", .{ char_slice, char_slice, @tagName(cache_record.value_ptr.load_mode), @tagName(args.load_mode) });
            return cache_record.value_ptr;
        }
        cache_log.debug("Cached glyph had lower load_mode: '{s}', {s} -> {s}", .{ char_slice, @tagName(cache_record.value_ptr.load_mode), @tagName(args.load_mode) });
    } else {
        cache_log.debug("Cache miss on glyph: '{s}' with size: {}", .{ char_slice, args.font_size });
    }

    cache_record.value_ptr.* = self.loadCharNoCache(char, args);

    return cache_record.value_ptr;
}

pub fn loadCharNoCache(self: *FreeTypeContext, char: u21, args: LoadCharOptions) Glyph {
    self.setFontPixelSize(args.font_size);

    const freetype_flags: i32 = switch (args.load_mode) {
        .default => freetype.FT_LOAD_DEFAULT,
        .metrics => freetype.FT_LOAD_COMPUTE_METRICS,
        .render => freetype.FT_LOAD_RENDER | freetype.FT_LOAD_COMPUTE_METRICS,
    };

    var ft_transform = freetype.FT_Matrix{
        .xx = args.transform.xx,
        .xy = args.transform.xy,
        .yx = args.transform.yx,
        .yy = args.transform.yy,
    };

    freetype.FT_Set_Transform(self.font_face, &ft_transform, null);

    const err = freetype.FT_Load_Char(self.font_face, char, freetype_flags);

    if (freetype_utils.isErr(err)) {
        freetype_utils.errorPrint(err, "Failed to load Glyph with", .{});

        // if it errors, load a replacement glyph
        const err_rep = freetype.FT_Load_Glyph(self.font_face, 0, freetype_flags);
        freetype_utils.errorAssert(err_rep, "Failed to load replacement Glyph with", .{});
    }

    if (@intFromEnum(args.load_mode) >= @intFromEnum(LoadMode.render)) assert(self.font_face.*.glyph.*.bitmap.buffer != null);

    return Glyph.from(self.allocator, self.font_face.*.glyph, args.load_mode, args.transform);
}

pub const DrawCharArgs = struct {
    draw_context: *const DrawContext,
    text_color: Color,

    /// The maximum area it can take up.
    area: Rect,

    /// Only draw within this Rect if specified.
    /// Used for partial glyph drawing.
    within: ?Rect = null,

    /// Draw this character.
    char: u21,

    /// Draw all the debugging bounding boxes.
    bounding_box: bool,

    /// Disable alpha, and just put color at full strength
    no_alpha: bool = false,

    /// At this font size.
    font_size: Size,

    /// The transform of the bitmap
    transform: Transform,

    /// How to align horizontally the glyph in the maximum area.
    hori_align: Align,
    /// How to align vertically the glyph in the maximum area.
    vert_align: Align,

    /// Which width scaling option to use.
    width: WidthOptions,

    pub const WidthOptions = union(enum) {
        /// Make the max glyph area a specific width.
        fixed: Size,
        /// Scale the glyph's advance width by a function.
        scaling: *const fn (Size) Size,
        /// just use the glyph's advance width
        advance,
    };
};

/// Draw the given character
/// Returns the width of the max area.
pub fn drawChar(freetype_context: *FreeTypeContext, args: DrawCharArgs) void {
    const glyph = freetype_context.loadChar(args.char, .{
        .font_size = args.font_size,
        .transform = args.transform,
        .load_mode = .render,
    });

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

    // Metrics are no updated with the transform.
    const origin = if (glyph.metrics) |metrics| origin: {
        const glyph_height: Size = @intCast(metrics.height >> 6);
        const glyph_upper: Size = @intCast(metrics.horiBearingY >> 6);

        break :origin Point{
            .x = @intCast(glyph_area.x - glyph.bitmap_left),
            .y = glyph_area.y + glyph_area.height - glyph_height + glyph_upper,
        };
    } else Point{
        .x = @intCast(glyph_area.x - glyph.bitmap_left),
        .y = glyph_area.y + glyph.*.bitmap_height,
    };

    drawBitmap(args.draw_context, .{
        .text_color = args.text_color,
        .no_alpha = args.no_alpha,
        .max_area = args.within orelse glyph_area,
        .origin = origin,
        .glyph = glyph,
    });

    if (args.bounding_box) {
        max_glyph_area.drawOutline(args.draw_context, colors.love);
        glyph_area.drawOutline(args.draw_context, colors.border);
    }
}

fn cleanCache(self: *FreeTypeContext) void {
    log.info("Cleaning Cache...", .{});
    defer log.info("Done Cache...", .{});
    // 20% of total glyphs.
    const num_to_remove = options.freetype_cache_size / (5 * @sizeOf(Glyph));

    const CleanInfo = struct {
        key: CacheKey,
        time: i64,

        pub fn lessThan(ctx: void, lhs: @This(), rhs: @This()) bool {
            _ = ctx;
            return lhs.time < rhs.time;
        }
    };

    var glyphs_to_remove = BoundedArray(CleanInfo, num_to_remove){};

    {
        var iter = self.cache.iterator();
        const cache_length = self.cache.count();

        for (0..num_to_remove) |_| {
            const glyph = iter.next() orelse break;

            glyphs_to_remove.append(.{
                .key = glyph.key_ptr.*,
                .time = glyph.value_ptr.time,
            }) catch unreachable;
        }

        mem.sort(CleanInfo, glyphs_to_remove.slice(), {}, CleanInfo.lessThan);

        var loop_counter: usize = 0;

        while (iter.next()) |entry| : (loop_counter += 1) {
            assert(loop_counter <= cache_length);

            const clean_info = CleanInfo{
                .key = entry.key_ptr.*,
                .time = entry.value_ptr.time,
            };
            const lower_bound = std.sort.lowerBound(CleanInfo, clean_info, glyphs_to_remove.slice(), {}, CleanInfo.lessThan);

            if (lower_bound < num_to_remove) {
                _ = glyphs_to_remove.pop();
                glyphs_to_remove.insert(lower_bound, clean_info) catch unreachable;
            }
        }
    }

    for (glyphs_to_remove.slice()) |entry| {
        // unreachable because they have to exist (we just found them).
        var glyph = self.cache.fetchSwapRemove(entry.key) orelse unreachable;
        glyph.value.deinit(self.allocator);
    }
}

test global {
    try init_global(std.testing.allocator, null);
    defer global.deinit();
}

const DrawContext = @import("DrawContext.zig");
const Config = @import("Config.zig");

const drawing = @import("drawing.zig");
const SizeSigned = drawing.SizeSigned;
const Transform = drawing.Transform;
const Align = drawing.Align;
const Point = drawing.Point;
const Rect = drawing.Rect;
const Size = drawing.Size;

const colors = @import("colors.zig");
const Color = colors.Color;

const Path = @import("Config.zig").Path;

const drawBitmap = @import("draw_bitmap.zig").drawBitmap;

const freetype_utils = @import("freetype_utils.zig");
const freetype = freetype_utils.freetype;

const options = @import("options");
const font = @import("font");

const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const fs = std.fs;

const Allocator = mem.Allocator;
const AutoArrayHashMap = std.AutoArrayHashMap;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const BoundedArray = std.BoundedArray;

const assert = std.debug.assert;
const unicode = std.unicode;
const runtime_safety = std.debug.runtime_safety;

const log = std.log.scoped(.FreeTypeContext);
const cache_log = std.log.scoped(.FreeTypeCache);
