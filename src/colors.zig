// ARGB is in reverse order for little endian (required by wayland spec)
pub const Color = packed struct(u32) {
    b: u8,
    g: u8,
    r: u8,
    a: u8,

    pub const FORMAT: wl.Shm.Format = .argb8888;

    pub fn withAlpha(self: Color, alpha: u8) Color {
        var new = self;
        new.a = alpha;
        return new;
    }

    pub fn composite(bg: Color, fg: Color) Color {
        const ratio = @as(f32, @floatFromInt(fg.a)) / 255.0;
        const ratio_old = @max(1.0 - ratio, 0.0);

        const r_fg, const g_fg, const b_fg = .{ @as(f32, @floatFromInt(fg.r)), @as(f32, @floatFromInt(fg.g)), @as(f32, @floatFromInt(fg.b)) };
        const r_bg, const g_bg, const b_bg = .{ @as(f32, @floatFromInt(bg.r)), @as(f32, @floatFromInt(bg.g)), @as(f32, @floatFromInt(bg.b)) };

        return .{
            .a = bg.a +| fg.a,
            .r = @intFromFloat(ratio * r_fg + ratio_old * r_bg),
            .g = @intFromFloat(ratio * g_fg + ratio_old * g_bg),
            .b = @intFromFloat(ratio * b_fg + ratio_old * b_bg),
        };
    }

    test composite {
        const expect = std.testing.expect;

        const compos = @as(u32, @bitCast(composite(all_colors.black, all_colors.main)));
        const color = @as(u32, @bitCast(all_colors.main));

        try expect(compos == color);
    }
};

/// turns a rgb int into a color
pub fn rgb2Color(int: u24) Color {
    var val: u32 = int;
    val |= 0xFF_00_00_00;
    return @bitCast(val);
}

test rgb2Color {
    const expectEqual = std.testing.expectEqual;

    try expectEqual(
        @as(u32, @bitCast(rgb2Color(0x112233))),
        0xFF112233,
    );

    try expectEqual(
        rgb2Color(0x112233),
        Color{
            .a = 0xFF,
            .r = 0x11,
            .g = 0x22,
            .b = 0x33,
        },
    );
}

pub fn rgba2argb(rgba: Color) Color {
    var color = rgba;
    std.mem.rotate(u8, std.mem.asBytes(&color), 1);
    return color;
}

test rgba2argb {
    const expectEqual = std.testing.expectEqual;

    try expectEqual(
        0x11223344,
        @as(u32, @bitCast(rgba2argb(@bitCast(@as(u32, 0x22334411))))),
    );
}

pub const Str2ColorError = error{
    @"Color string is empty",
    @"Illegal character in color hex string",
    @"Color hex code invalid length",
    @"Color hex string too long",
    @"Color hex string too short",
    @"Color not found, or forgot '#' in front of hex code",
};

/// turns a rgba hex string into a color
pub fn str2Color(str: []const u8) Str2ColorError!Color {
    if (str.len == 0) return error.@"Color string is empty";

    inline for (COLOR_LIST) |color| {
        if (std.ascii.eqlIgnoreCase(color.name, str)) return color.color;
    }

    var color: u32 = 0;

    if (str[0] != '#') return error.@"Color not found, or forgot '#' in front of hex code";

    if (str.len < 4) return error.@"Color hex string too short";

    var digit_count: u4 = 0;

    for (str[1..]) |char| {
        if (digit_count >= 8) return error.@"Color hex string too long";

        if (char == '_') continue;

        if (!ascii.isHex(char)) return error.@"Illegal character in color hex string";

        const c = ascii.toUpper(char);

        color <<= 4;
        color |= @as(u4, @truncate(c));
        if ('A' <= c and c <= 'F') color += 9;

        digit_count += 1;
    }

    if (digit_count == 4) { // given #rgba
        assert(color <= std.math.maxInt(u16));
        color =
            ((color & 0x00_0F) << 24) | // alpha
            ((color & 0xF0_00) << 4) | // red
            ((color & 0x0F_00)) | // green
            ((color & 0x00_F0) >> 4); // blue

        color |= color << 4;

        return @bitCast(color);
    } else if (digit_count == 3) { // given #rgb
        assert(color <= std.math.maxInt(u12));
        color =
            ((color & 0x0F_00) << 8) | // red
            ((color & 0x00_F0) << 4) | // green
            ((color & 0x00_0F)); // blue

        color |= 0x0F_00_00_00;
        color |= color << 4;

        return @bitCast(color);
    } else if (digit_count == 6) { // given #rrggbb
        assert(color <= std.math.maxInt(u24));
        return @bitCast(color | 0xFF_00_00_00); // add opaque to alpha-less codes
    } else if (digit_count == 8) { // given #rrggbbaa
        return rgba2argb(@bitCast(color));
    } else {
        return error.@"Color hex code invalid length";
    }
}

test str2Color {
    const expectEqual = std.testing.expectEqual;

    try expectEqual(0xFF191724, @as(u32, @bitCast(try str2Color("main"))));
    try expectEqual(0x44112233, @as(u32, @bitCast(try str2Color("#11223344"))));
    try expectEqual(0xFF112233, @as(u32, @bitCast(try str2Color("#112233"))));
    try expectEqual(0x44112233, @as(u32, @bitCast(try str2Color("#1234"))));
    try expectEqual(0xFF112233, @as(u32, @bitCast(try str2Color("#123"))));
}

// Simply blends the two colors together by multiplying them by the `fg`'s alpha/255

pub const all_colors = struct {
    // TODO: Add more colors here.
    pub const clear: Color = @bitCast(@as(u32, 0));
    pub const white: Color = @bitCast(@as(u32, 0xFF_FF_FF_FF));
    pub const black: Color = @bitCast(@as(u32, 0xFF_00_00_00));
    pub const main: Color = @bitCast(@as(u32, 0xFF191724));
    pub const surface: Color = @bitCast(@as(u32, 0xFF1f1d2e));
    pub const overlay: Color = @bitCast(@as(u32, 0xFF26233a));
    pub const muted: Color = @bitCast(@as(u32, 0xFF908caa));
    pub const text: Color = @bitCast(@as(u32, 0xFFe0def4));
    pub const love: Color = @bitCast(@as(u32, 0xFFeb6f92));
    pub const gold: Color = @bitCast(@as(u32, 0xFFf6c177));
    pub const rose: Color = @bitCast(@as(u32, 0xFFebbcba));
    pub const pine: Color = @bitCast(@as(u32, 0xFF31748f));
    pub const foam: Color = @bitCast(@as(u32, 0xFF9ccfd8));
    pub const iris: Color = @bitCast(@as(u32, 0xFFc4a7e7));
    pub const hl_low: Color = @bitCast(@as(u32, 0xFF21202e));
    pub const hl_med: Color = @bitCast(@as(u32, 0xFF403d52));
    pub const hl_high: Color = @bitCast(@as(u32, 0xFF524f67));

    pub const damage: Color = love;
    pub const border: Color = foam;
};
pub usingnamespace all_colors;

pub const ALL_COLORS_LEN = @typeInfo(all_colors).Struct.decls.len;

pub const ColorListElement = struct { color: Color, name: []const u8 };
pub const COLOR_LIST: [ALL_COLORS_LEN]ColorListElement = generate_color_list(all_colors);

fn generate_color_list(obj: anytype) [@typeInfo(obj).Struct.decls.len]ColorListElement {
    const type_info = @typeInfo(obj);

    assert(type_info.Struct.decls.len > 0);
    var list: [type_info.Struct.decls.len]ColorListElement = undefined;

    inline for (type_info.Struct.decls, 0..) |decl, idx| {
        list[idx] = .{
            .color = @field(obj, decl.name),
            .name = decl.name,
        };
    }

    return list;
}

const wayland = @import("wayland");
const wl = wayland.client.wl;

const std = @import("std");
const assert = std.debug.assert;
const ascii = std.ascii;
