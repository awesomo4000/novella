// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const sheet = @import("sheet");
const shaping = @import("text_engine");
const Surface = @import("surface.zig").Surface;

const ft = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

pub const Engine = struct {
    library: ft.FT_Library,
    face: ft.FT_Face,

    /// `font_bytes` must remain alive and unchanged until `deinit` returns.
    pub fn init(font_bytes: []const u8, pixel_size: f64) !Engine {
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

        return .{ .library = library, .face = face };
    }

    pub fn deinit(self: *Engine) void {
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
            if (glyph.id > std.math.maxInt(ft.FT_UInt)) return error.GlyphIdentifierTooLarge;
            if (ft.FT_Load_Glyph(
                self.face,
                @intCast(glyph.id),
                ft.FT_LOAD_DEFAULT | ft.FT_LOAD_NO_BITMAP,
            ) != 0) return error.FreeTypeGlyphLoadFailed;
            const slot = self.face.*.glyph;
            if (ft.FT_Render_Glyph(slot, ft.FT_RENDER_MODE_NORMAL) != 0)
                return error.FreeTypeGlyphRenderFailed;
            try blendBitmap(
                surface,
                &slot.*.bitmap,
                @as(i32, @intFromFloat(@round(pen_x + glyph.x_offset))) + slot.*.bitmap_left,
                @as(i32, @intFromFloat(@round(pen_y - glyph.y_offset))) - slot.*.bitmap_top,
                color,
            );
            pen_x += glyph.x_advance;
            pen_y -= glyph.y_advance;
        }
    }
};

fn blendBitmap(
    surface: *Surface,
    bitmap: *const ft.FT_Bitmap,
    left: i32,
    top: i32,
    color: sheet.Color,
) !void {
    if (bitmap.*.pixel_mode != ft.FT_PIXEL_MODE_GRAY)
        return error.UnsupportedFreeTypePixelMode;
    if (bitmap.*.width == 0 or bitmap.*.rows == 0) return;
    if (bitmap.*.buffer == null or bitmap.*.num_grays < 2)
        return error.InvalidFreeTypeBitmap;

    const pitch: i32 = bitmap.*.pitch;
    const row_stride: usize = @intCast(@abs(pitch));
    const rows: usize = bitmap.*.rows;
    const columns: usize = bitmap.*.width;
    for (0..rows) |row| {
        const source_row = if (pitch >= 0) row else rows - 1 - row;
        const row_start = source_row * row_stride;
        for (0..columns) |column| {
            const raw = bitmap.*.buffer[row_start + column];
            const coverage: u8 = @intCast((@as(u32, raw) * 255 + (bitmap.*.num_grays - 1) / 2) /
                (bitmap.*.num_grays - 1));
            surface.blendPixel(
                left + @as(i32, @intCast(column)),
                top + @as(i32, @intCast(row)),
                color,
                coverage,
            );
        }
    }
}
