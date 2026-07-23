// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const _frame_request = @import("frame_request.zig");
const sheet = @import("sheet");
const shaping = @import("text_engine");
const font_data = @import("font_data");
const rasterizer = @import("freetype.zig");
const Surface = @import("surface.zig").Surface;

comptime {
    _ = _frame_request;
}

test "FreeType blends HarfBuzz-selected Junicode glyphs into the X11 surface" {
    const allocator = std.testing.allocator;
    const font_bytes = try font_data.loadJunicode(allocator);
    defer allocator.free(font_bytes);

    var text_engine = try shaping.Engine.init(font_bytes, sheet.body_font_size);
    defer text_engine.deinit();
    var glyph_engine = try rasterizer.Engine.init(font_bytes, sheet.body_font_size);
    defer glyph_engine.deinit();

    var surface = try Surface.init(allocator, .{
        .bits_per_pixel = 32,
        .scanline_pad = 32,
        .lsb_first = true,
        .red_mask = 0x00ff0000,
        .green_mask = 0x0000ff00,
        .blue_mask = 0x000000ff,
    });
    defer surface.deinit();
    try surface.resize(240, 80);
    surface.fill(sheet.paper);
    const blank = try allocator.dupe(u8, surface.pixels);
    defer allocator.free(blank);

    var run = try text_engine.shape(allocator, "office AVATAR café");
    defer run.deinit(allocator);
    try glyph_engine.drawRun(&surface, run, 12, 44, sheet.ink);

    try std.testing.expect(!std.mem.eql(u8, blank, surface.pixels));
}
