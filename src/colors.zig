// ARGB is in reverse order for little endian (required by wayland spec)
pub const Color = packed struct(u32) {
    b: u8,
    g: u8,
    r: u8,
    a: u8,

    // TODO: Support multiple color formats. (we won't need to for a long time though)
    pub const FORMAT: wl.Shm.Format = .argb8888;

    pub fn withAlpha(self: Color, alpha: u8) Color {
        var new = self;
        new.a = alpha;
        return new;
    }

    //pub fn composite(bg: Color, fg: Color) Color {
    //    const ratio = @as(f32, @floatFromInt(fg.a)) / 255.0;
    //    const ratio_old = @max(1.0 - ratio, 0.0);

    //    const r_fg, const g_fg, const b_fg = .{ @as(f32, @floatFromInt(fg.r)), @as(f32, @floatFromInt(fg.g)), @as(f32, @floatFromInt(fg.b)) };
    //    const r_bg, const g_bg, const b_bg = .{ @as(f32, @floatFromInt(bg.r)), @as(f32, @floatFromInt(bg.g)), @as(f32, @floatFromInt(bg.b)) };

    //    return .{
    //        .a = bg.a +| fg.a,
    //        .r = @intFromFloat(ratio * r_fg + ratio_old * r_bg),
    //        .g = @intFromFloat(ratio * g_fg + ratio_old * g_bg),
    //        .b = @intFromFloat(ratio * b_fg + ratio_old * b_bg),
    //    };
    //}

    // TODO: Make sure this is correct.
    pub fn composite(bg: Color, fg: Color) Color {
        if (fg.a == maxInt(u8)) return fg;

        const ratio: u16 = fg.a;
        assert(ratio <= maxInt(u8));
        const ratio_old: u16 = @as(u16, maxInt(u8)) - ratio;

        assert(ratio + ratio_old == maxInt(u8));

        // if over 1/2 of the remaining color is there after the 8 bit truncation for one,
        // but not both the foreground and background.
        const add_one_r = (fg.r * ratio & (1 << 7)) ^ (bg.r * (ratio_old + 1) & (1 << 7)) > 0;
        const add_one_g = (fg.g * ratio & (1 << 7)) ^ (bg.g * (ratio_old + 1) & (1 << 7)) > 0;
        const add_one_b = (fg.b * ratio & (1 << 7)) ^ (bg.b * (ratio_old + 1) & (1 << 7)) > 0;

        return .{
            .a = fg.a +| bg.a,
            .r = @intCast((fg.r * ratio / maxInt(u8)) + (bg.r * ratio_old / maxInt(u8)) + @intFromBool(add_one_r)),
            .g = @intCast((fg.g * ratio / maxInt(u8)) + (bg.g * ratio_old / maxInt(u8)) + @intFromBool(add_one_g)),
            .b = @intCast((fg.b * ratio / maxInt(u8)) + (bg.b * ratio_old / maxInt(u8)) + @intFromBool(add_one_b)),
        };
    }

    test composite {
        const expect = std.testing.expect;

        for (COLOR_LIST) |color| {
            const compos = composite(color.color, all_colors.main);
            try expect(meta.eql(all_colors.main, compos));
        }

        for (COLOR_LIST) |color| {
            const compos_clear = composite(color.color, all_colors.clear);
            try expect(meta.eql(color.color, compos_clear));
        }
    }

    // Simply blends the two colors together by multiplying them by the `fg`'s alpha/255
    pub fn blend(a: Color, b: Color, ratio: u8) Color {
        return a.composite(b.withAlpha(ratio));
    }

    /// returns if the color is dark according to https://www.w3.org/TR/2008/REC-WCAG20-20081211/#relativeluminancedef
    pub fn isDark(self: Color) bool {
        return 0.2126 * flumi(self.r) + 0.7152 * flumi(self.g) + 0.0722 * flumi(self.b) <= 0.17913;
    }

    fn flumi(component: u8) f32 {
        const c = @as(f32, @floatFromInt(component)) / 255.0;

        return if (c <= 0.03928) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
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

pub const ParseColorError = error{
    @"Color string is empty",
    @"Illegal character in color hex string",
    @"Color hex code invalid length",
    @"Color hex string too long",
    @"Color hex string too short",
    @"Color not found, or forgot '#' in front of hex code",
};

/// turns a rgba hex string into a color
pub fn parseColor(str: []const u8) ParseColorError!Color {
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

test parseColor {
    const expectEqual = std.testing.expectEqual;

    try expectEqual(0xFF191724, @as(u32, @bitCast(try parseColor("main"))));
    try expectEqual(0x44112233, @as(u32, @bitCast(try parseColor("#11223344"))));
    try expectEqual(0xFF112233, @as(u32, @bitCast(try parseColor("#112233"))));
    try expectEqual(0x44112233, @as(u32, @bitCast(try parseColor("#1234"))));
    try expectEqual(0xFF112233, @as(u32, @bitCast(try parseColor("#123"))));
}

pub fn comptimeColorToString(comptime color: Color) []const u8 {
    for (COLOR_LIST) |item| {
        if (std.meta.eql(item.color, color)) return item.name;
    }

    return std.fmt.comptimePrint("#{x:2}{x:2}{x:2}{x:2}", .{ color.r, color.b, color.g, color.a });
}

pub const all_colors = struct {
    // TODO: Add more colors here.
    pub const clear: Color = @bitCast(@as(u32, 0));
    pub const white: Color = @bitCast(@as(u32, 0xFFCFD3CB));
    pub const black: Color = @bitCast(@as(u32, 0xFF030501));
    pub const red: Color = @bitCast(@as(u32, 0xFFCA0202));
    pub const green: Color = @bitCast(@as(u32, 0xFF4D9706));
    pub const yellow: Color = @bitCast(@as(u32, 0xFFC49D00));
    pub const blue: Color = @bitCast(@as(u32, 0xFF709FCE));
    pub const magenta: Color = @bitCast(@as(u32, 0xFF75527D));
    pub const cyan: Color = @bitCast(@as(u32, 0xFF0A999B));

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
};
pub usingnamespace all_colors;

pub const color_aliases = struct {
    pub const damage: Color = all_colors.love;
    pub const border: Color = all_colors.foam;
    pub const none: Color = all_colors.clear;
};
pub usingnamespace color_aliases;

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

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Color);
}

const wayland = @import("wayland");
const wl = wayland.client.wl;

const std = @import("std");
const ascii = std.ascii;
const meta = std.meta;

const maxInt = std.math.maxInt;
const assert = std.debug.assert;
