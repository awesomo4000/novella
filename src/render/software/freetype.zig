// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const builtin = @import("builtin");
const sheet = @import("sheet");
const shaping = @import("text_engine");
const Surface = @import("surface.zig").Surface;

const ft = @cImport({
    if (builtin.cpu.arch == .x86 and builtin.os.tag == .windows)
        @cDefine("_X86_", "1");
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

pub const Engine = struct {
    allocator: std.mem.Allocator,
    library: ft.FT_Library,
    face: ft.FT_Face,
    glyphs: std.AutoHashMapUnmanaged(u32, GlyphBitmap) = .empty,

    /// `font_bytes` must remain alive and unchanged until `deinit` returns.
    pub fn init(
        allocator: std.mem.Allocator,
        font_bytes: []const u8,
        pixel_size: f64,
    ) !Engine {
        if (font_bytes.len > std.math.maxInt(ft.FT_Long)) return error.FontTooLarge;
        if (!(pixel_size > 0) or !std.math.isFinite(pixel_size)) return error.InvalidFontSize;

        var library: ft.FT_Library = null;
        if (ft.FT_Init_FreeType(&library) != 0) return error.FreeTypeInitializationFailed;
        errdefer _ = ft.FT_Done_FreeType(library);

        var face: ft.FT_Face = null;
        if (ft.FT_New_Memory_Face(
            library,
            font_bytes.ptr,
            @intCast(font_bytes.len),
            0,
            &face,
        ) != 0) return error.FreeTypeFontLoadFailed;
        errdefer _ = ft.FT_Done_Face(face);

        const rounded_size = @round(pixel_size);
        if (rounded_size < 1 or rounded_size > std.math.maxInt(c_uint))
            return error.InvalidFontSize;
        if (ft.FT_Set_Pixel_Sizes(face, 0, @intFromFloat(rounded_size)) != 0)
            return error.FreeTypeSizeFailed;

        return .{ .allocator = allocator, .library = library, .face = face };
    }

    pub fn deinit(self: *Engine) void {
        var iterator = self.glyphs.valueIterator();
        while (iterator.next()) |glyph| glyph.deinit(self.allocator);
        self.glyphs.deinit(self.allocator);
        _ = ft.FT_Done_Face(self.face);
        _ = ft.FT_Done_FreeType(self.library);
        self.* = undefined;
    }

    pub fn drawRun(
        self: *Engine,
        surface: *Surface,
        run: shaping.Run,
        origin_x: f64,
        baseline_y: f64,
        color: sheet.Color,
    ) !void {
        var pen_x = origin_x;
        var pen_y = baseline_y;
        for (run.glyphs) |glyph| {
            const bitmap = try self.glyphBitmap(glyph.id);
            blendBitmap(
                surface,
                bitmap,
                @as(i32, @intFromFloat(@round(pen_x + glyph.x_offset))) + bitmap.left,
                @as(i32, @intFromFloat(@round(pen_y - glyph.y_offset))) - bitmap.top,
                color,
            );
            pen_x += glyph.x_advance;
            pen_y -= glyph.y_advance;
        }
    }

    pub fn cachedGlyphCount(self: *const Engine) usize {
        return self.glyphs.count();
    }

    fn glyphBitmap(self: *Engine, glyph_id: u32) !GlyphBitmap {
        if (self.glyphs.get(glyph_id)) |glyph| return glyph;
        const glyph = try rasterizeGlyph(self.allocator, self.face, glyph_id);
        errdefer {
            var owned = glyph;
            owned.deinit(self.allocator);
        }
        try self.glyphs.put(self.allocator, glyph_id, glyph);
        return glyph;
    }
};

const GlyphBitmap = struct {
    left: i32,
    top: i32,
    width: usize,
    rows: usize,
    coverage: []u8,

    fn deinit(self: *GlyphBitmap, allocator: std.mem.Allocator) void {
        if (self.coverage.len > 0) allocator.free(self.coverage);
        self.* = undefined;
    }
};

fn rasterizeGlyph(
    allocator: std.mem.Allocator,
    face: ft.FT_Face,
    glyph_id: u32,
) !GlyphBitmap {
    if (glyph_id > std.math.maxInt(ft.FT_UInt)) return error.GlyphIdentifierTooLarge;
    if (ft.FT_Load_Glyph(
        face,
        @intCast(glyph_id),
        ft.FT_LOAD_DEFAULT | ft.FT_LOAD_NO_BITMAP,
    ) != 0) return error.FreeTypeGlyphLoadFailed;
    const slot = face.*.glyph;
    if (ft.FT_Render_Glyph(slot, ft.FT_RENDER_MODE_NORMAL) != 0)
        return error.FreeTypeGlyphRenderFailed;

    const bitmap = &slot.*.bitmap;
    const width: usize = bitmap.*.width;
    const rows: usize = bitmap.*.rows;
    if (width == 0 or rows == 0) return .{
        .left = slot.*.bitmap_left,
        .top = slot.*.bitmap_top,
        .width = width,
        .rows = rows,
        .coverage = &.{},
    };
    if (bitmap.*.pixel_mode != ft.FT_PIXEL_MODE_GRAY)
        return error.UnsupportedFreeTypePixelMode;
    if (bitmap.*.buffer == null or bitmap.*.num_grays < 2)
        return error.InvalidFreeTypeBitmap;

    const pitch: i32 = bitmap.*.pitch;
    const row_stride: usize = @intCast(@abs(pitch));
    if (row_stride < width) return error.InvalidFreeTypeBitmap;
    const coverage = try allocator.alloc(u8, try std.math.mul(usize, width, rows));
    errdefer allocator.free(coverage);
    for (0..rows) |row| {
        const source_row = if (pitch >= 0) row else rows - 1 - row;
        const row_start = source_row * row_stride;
        for (0..width) |column| {
            const raw = bitmap.*.buffer[row_start + column];
            coverage[row * width + column] = @intCast(
                (@as(u32, raw) * 255 + (bitmap.*.num_grays - 1) / 2) /
                    (bitmap.*.num_grays - 1),
            );
        }
    }
    return .{
        .left = slot.*.bitmap_left,
        .top = slot.*.bitmap_top,
        .width = width,
        .rows = rows,
        .coverage = coverage,
    };
}

fn blendBitmap(
    surface: *Surface,
    bitmap: GlyphBitmap,
    left: i32,
    top: i32,
    color: sheet.Color,
) void {
    for (0..bitmap.rows) |row| {
        for (0..bitmap.width) |column| {
            surface.blendPixel(
                left + @as(i32, @intCast(column)),
                top + @as(i32, @intCast(row)),
                color,
                bitmap.coverage[row * bitmap.width + column],
            );
        }
    }
}
