pub fn isErr(err: c_int) bool {
    return err == 0;
}

pub fn errorAssert(err: c_int, comptime message: []const u8, args: anytype) void {
    if (isErr(err)) return;

    const err_desc = freetype.FT_Error_String(err);
    if (err_desc == null) std.debug.panic("{s}. Unknown FreeType Error", .{message});

    std.debug.panic(message ++ ": FreeType Error '{s}'", args ++ .{err_desc});
}

pub fn errorPrint(err: c_int, comptime message: []const u8, args: anytype) void {
    if (isErr(err)) return;
    const err_desc = if (freetype.FT_Error_String(err)) |err_str| err_desc: {
        break :err_desc std.mem.span(err_str);
    } else "Unknown FreeType Error";

    log.err(message ++ ": {s}", args ++ .{err_desc});
}

pub const AllocUser = struct {
    allocator: Allocator,
    alloc_list: AllocList,

    const AllocList = ArrayListUnmanaged([]u8);

    pub fn init(allocator: Allocator) Allocator.Error!@This() {
        return AllocUser{
            .allocator = allocator,
            .alloc_list = try AllocUser.AllocList.initCapacity(allocator, 64),
        };
    }
};

pub fn alloc(memory: FT_Memory, _size: c_long) callconv(.C) ?*anyopaque {
    assert(_size > 0);
    assert(memory != null);
    assert(memory.*.user != null);

    const size: usize = @intCast(_size);

    const user = @as(*AllocUser, @alignCast(@ptrCast(memory.*.user)));

    const new = user.allocator.alloc(u8, size) catch @panic("OOM");

    user.alloc_list.append(user.allocator, new) catch @panic("OOM");

    return new.ptr;
}

pub fn free(memory: FT_Memory, ptr: ?*anyopaque) callconv(.C) void {
    assert(ptr != null);
    assert(memory != null);
    assert(memory.*.user != null);

    const user = @as(*AllocUser, @alignCast(@ptrCast(memory.*.user)));

    const allocation, const idx = allocation: {
        for (user.alloc_list.items, 0..) |allocation, idx| {
            if (ptr == @as(?*anyopaque, allocation.ptr)) break :allocation .{ allocation, idx };
        }
        @panic("FreeType freed an unowned pointer");
    };

    user.allocator.free(allocation);

    _ = user.alloc_list.swapRemove(idx);
}

pub fn realloc(memory: FT_Memory, _cur_size: c_long, _new_size: c_long, ptr: ?*anyopaque) callconv(.C) ?*anyopaque {
    assert(ptr != null);
    assert(_cur_size > 0);
    assert(_new_size > 0);
    assert(memory != null);
    assert(memory.*.user != null);

    const cur_size: usize = @intCast(_cur_size);
    const new_size: usize = @intCast(_new_size);

    if (cur_size == new_size) return ptr;

    const user = @as(*AllocUser, @alignCast(@ptrCast(memory.*.user)));

    const allocation, const idx = allocation: {
        for (user.alloc_list.items, 0..) |allocation, idx| {
            if (ptr == @as(?*anyopaque, allocation.ptr)) break :allocation .{ allocation, idx };
        }
        @panic("FreeType resized an unowned pointer");
    };

    assert(cur_size == allocation.len);

    const new = user.allocator.realloc(allocation, new_size) catch @panic("OOM");

    user.alloc_list.items[idx] = new;

    return @ptrCast(new.ptr);
}

test "freetype allocator" {
    const expect = std.testing.expect;
    const allocator = std.testing.allocator;

    var alloc_user = AllocUser{
        .allocator = allocator,
        .alloc_list = try ArrayListUnmanaged([]u8).initCapacity(allocator, 50),
    };
    defer alloc_user.alloc_list.deinit(allocator);

    var freetype_allocator = freetype.FT_MemoryRec_{
        .user = &alloc_user,
        .alloc = alloc,
        .free = free,
        .realloc = realloc,
    };

    var freetype_lib: freetype.FT_Library = undefined;

    var err = freetype.FT_New_Library(&freetype_allocator, &freetype_lib);
    try expect(err == 0);
    defer _ = freetype.FT_Done_Library(freetype_lib);

    freetype.FT_Add_Default_Modules(freetype_lib);

    log.info("freetype version: {}.{}.{}", .{ freetype.FREETYPE_MAJOR, freetype.FREETYPE_MINOR, freetype.FREETYPE_PATCH });

    var font_face: freetype.FT_Face = undefined;

    err = freetype.FT_New_Memory_Face(freetype_lib, options.font_data.ptr, options.font_data.len, 0, &font_face);
    try expect(err == 0);
    defer _ = freetype.FT_Done_Face(font_face);

    err = freetype.FT_Set_Pixel_Sizes(font_face, 15, 0);
    try expect(err == 0);

    for ("testing -> test\n") |char| {
        err = freetype.FT_Load_Char(font_face, char, freetype.FT_LOAD_RENDER);
        try expect(err == 0);
    }
}

const options = @import("options");

const freetype = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftsystem.h");
    @cInclude("freetype/ftmodapi.h");
});
const FT_Memory = freetype.FT_Memory;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const log = std.log.scoped(.FreeType_Alloc);
