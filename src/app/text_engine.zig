// SPDX-License-Identifier: MPL-2.0

const std = @import("std");

const hb = @cImport({
    @cInclude("hb.h");
    @cInclude("hb-ot.h");
});

const position_scale: f64 = 64.0;

pub const Glyph = struct {
    id: u32,
    cluster: u32,
    x_advance: f64,
    y_advance: f64,
    x_offset: f64,
    y_offset: f64,
};

pub const Run = struct {
    glyphs: []Glyph,
    advance: f64,

    pub fn deinit(self: *Run, allocator: std.mem.Allocator) void {
        allocator.free(self.glyphs);
        self.* = undefined;
    }
};

pub const Engine = struct {
    blob: *hb.hb_blob_t,
    face: *hb.hb_face_t,
    font: *hb.hb_font_t,

    /// `font_bytes` must remain alive and unchanged until `deinit` returns.
    pub fn init(font_bytes: []const u8, point_size: f64) !Engine {
        if (font_bytes.len > std.math.maxInt(c_uint)) return error.FontTooLarge;
        if (!(point_size > 0) or !std.math.isFinite(point_size))
            return error.InvalidFontSize;
        const scaled_size = @round(point_size * position_scale);
        if (scaled_size < 1 or scaled_size > @as(f64, @floatFromInt(std.math.maxInt(c_int))))
            return error.InvalidFontSize;

        const blob = hb.hb_blob_create(
            font_bytes.ptr,
            @intCast(font_bytes.len),
            hb.HB_MEMORY_MODE_READONLY,
            null,
            null,
        ) orelse return error.HarfBuzzAllocationFailed;
        errdefer hb.hb_blob_destroy(blob);

        const face = hb.hb_face_create(blob, 0) orelse
            return error.HarfBuzzAllocationFailed;
        errdefer hb.hb_face_destroy(face);
        if (hb.hb_face_get_upem(face) == 0) return error.InvalidFont;

        const font = hb.hb_font_create(face) orelse
            return error.HarfBuzzAllocationFailed;
        errdefer hb.hb_font_destroy(font);
        hb.hb_ot_font_set_funcs(font);

        const scale: c_int = @intFromFloat(scaled_size);
        hb.hb_font_set_scale(font, scale, scale);

        return .{ .blob = blob, .face = face, .font = font };
    }

    pub fn deinit(self: *Engine) void {
        hb.hb_font_destroy(self.font);
        hb.hb_face_destroy(self.face);
        hb.hb_blob_destroy(self.blob);
        self.* = undefined;
    }

    pub fn shape(self: *const Engine, allocator: std.mem.Allocator, utf8: []const u8) !Run {
        if (utf8.len > std.math.maxInt(c_int)) return error.TextTooLong;

        const buffer = hb.hb_buffer_create() orelse
            return error.HarfBuzzAllocationFailed;
        defer hb.hb_buffer_destroy(buffer);

        hb.hb_buffer_set_cluster_level(
            buffer,
            hb.HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS,
        );
        hb.hb_buffer_add_utf8(
            buffer,
            utf8.ptr,
            @intCast(utf8.len),
            0,
            @intCast(utf8.len),
        );
        hb.hb_buffer_set_language(buffer, hb.hb_language_from_string("und", -1));
        hb.hb_buffer_guess_segment_properties(buffer);
        if (hb.hb_buffer_allocation_successful(buffer) == 0)
            return error.HarfBuzzAllocationFailed;

        hb.hb_shape(self.font, buffer, null, 0);
        if (hb.hb_buffer_allocation_successful(buffer) == 0)
            return error.HarfBuzzAllocationFailed;

        var glyph_count: c_uint = 0;
        const infos = hb.hb_buffer_get_glyph_infos(buffer, &glyph_count);
        const positions = hb.hb_buffer_get_glyph_positions(buffer, &glyph_count);
        if (glyph_count != 0 and (infos == null or positions == null))
            return error.HarfBuzzAllocationFailed;

        const glyphs = try allocator.alloc(Glyph, glyph_count);
        errdefer allocator.free(glyphs);

        var advance: f64 = 0;
        for (glyphs, 0..) |*glyph, index| {
            const info = infos[index];
            const position = positions[index];
            glyph.* = .{
                .id = info.codepoint,
                .cluster = info.cluster,
                .x_advance = @as(f64, @floatFromInt(position.x_advance)) / position_scale,
                .y_advance = @as(f64, @floatFromInt(position.y_advance)) / position_scale,
                .x_offset = @as(f64, @floatFromInt(position.x_offset)) / position_scale,
                .y_offset = @as(f64, @floatFromInt(position.y_offset)) / position_scale,
            };
            advance += glyph.x_advance;
        }

        return .{ .glyphs = glyphs, .advance = advance };
    }
};
