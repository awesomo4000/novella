// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const RunCache = @import("run_cache.zig").RunCache;
const sheet = @import("sheet");
const shaping = @import("text_engine");
const font_data = @import("font_data");
const editing = @import("editor");
const rasterizer = @import("freetype.zig");
const renderer = @import("document_renderer.zig");
const paintDocument = renderer.paintDocument;
const Surface = @import("surface.zig").Surface;

test "FreeType blends HarfBuzz-selected Junicode glyphs into the software surface" {
    const allocator = std.testing.allocator;
    const font_bytes = try font_data.loadJunicode(allocator);
    defer allocator.free(font_bytes);

    var text_engine = try shaping.Engine.init(font_bytes, sheet.body_font_size);
    defer text_engine.deinit();
    var glyph_engine = try rasterizer.Engine.init(allocator, font_bytes, sheet.body_font_size);
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
    const cached_glyphs = glyph_engine.cachedGlyphCount();
    try std.testing.expect(cached_glyphs > 0);
    const first_render = try allocator.dupe(u8, surface.pixels);
    defer allocator.free(first_render);

    surface.fill(sheet.paper);
    try glyph_engine.drawRun(&surface, run, 12, 44, sheet.ink);
    try std.testing.expectEqual(cached_glyphs, glyph_engine.cachedGlyphCount());
    try std.testing.expectEqualSlices(u8, first_render, surface.pixels);
}

test "run cache reuses shapes for equal text" {
    const allocator = std.testing.allocator;
    const font_bytes = try font_data.loadJunicode(allocator);
    defer allocator.free(font_bytes);
    var text_engine = try shaping.Engine.init(font_bytes, sheet.body_font_size);
    defer text_engine.deinit();
    var run_cache = RunCache.init(allocator, &text_engine);
    defer run_cache.deinit();

    const first = try run_cache.shape("office");
    var duplicate = [_]u8{ 'o', 'f', 'f', 'i', 'c', 'e' };
    const second = try run_cache.shape(&duplicate);

    try std.testing.expectEqual(first.glyphs.ptr, second.glyphs.ptr);
}

test "complete document rendering is deterministic and reuses caches" {
    const allocator = std.testing.allocator;
    const font_bytes = try font_data.loadJunicode(allocator);
    defer allocator.free(font_bytes);
    var text_engine = try shaping.Engine.init(font_bytes, sheet.body_font_size);
    defer text_engine.deinit();
    var run_cache = RunCache.init(allocator, &text_engine);
    defer run_cache.deinit();
    var glyph_engine = try rasterizer.Engine.init(allocator, font_bytes, sheet.body_font_size);
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
    try surface.resize(900, 760);

    const text =
        "A complete paragraph is shaped with HarfBuzz, justified by Novella, " ++
        "and rasterized through the shared FreeType software renderer.";
    try paintDocument(&surface, text, &run_cache, &glyph_engine, 1.0);
    const first_frame = try allocator.dupe(u8, surface.pixels);
    defer allocator.free(first_frame);
    const run_count = run_cache.runs.count();
    const glyph_count = glyph_engine.cachedGlyphCount();
    try std.testing.expect(run_count > 0);
    try std.testing.expect(glyph_count > 0);

    try paintDocument(&surface, text, &run_cache, &glyph_engine, 1.0);
    try std.testing.expectEqual(run_count, run_cache.runs.count());
    try std.testing.expectEqual(glyph_count, glyph_engine.cachedGlyphCount());
    try std.testing.expectEqualSlices(u8, first_frame, surface.pixels);
}

test "software geometry preserves the logical sheet at 200 percent DPI" {
    const geometry = sheet.scaledGeometry(1800, 1520, 2.0);
    try std.testing.expectApproxEqAbs(@as(f64, 254), geometry.paper_left, 0.000_001);
    try std.testing.expectApproxEqAbs(@as(f64, 1292), geometry.paper_width, 0.000_001);
    try std.testing.expectApproxEqAbs(@as(f64, 402), geometry.content_left, 0.000_001);
    try std.testing.expectApproxEqAbs(@as(f64, 996), geometry.measure_width, 0.000_001);
}

test "explicit empty paragraphs receive distinct visual caret rows" {
    const allocator = std.testing.allocator;
    const font_bytes = try font_data.loadJunicode(allocator);
    defer allocator.free(font_bytes);
    var text_engine = try shaping.Engine.init(font_bytes, sheet.body_font_size);
    defer text_engine.deinit();
    var run_cache = RunCache.init(allocator, &text_engine);
    defer run_cache.deinit();
    var glyph_engine = try rasterizer.Engine.init(
        allocator,
        font_bytes,
        sheet.body_font_size,
    );
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
    try surface.resize(900, 760);

    const document = try allocator.create(editing.Editor);
    defer allocator.destroy(document);
    document.* = .{};
    try document.setText("first\n\nsecond");
    try renderer.paintEditor(
        &surface,
        document,
        &run_cache,
        &glyph_engine,
        1.0,
    );

    const first_blank = document.caretStopForOffset(6).?;
    const second_blank = document.caretStopForOffset(7).?;
    try std.testing.expectEqual(@as(usize, 1), first_blank.row);
    try std.testing.expectEqual(@as(usize, 2), second_blank.row);
    try std.testing.expect(second_blank.baseline > first_blank.baseline);
}

test "space after a line break stays on the new visual row" {
    const allocator = std.testing.allocator;
    const font_bytes = try font_data.loadJunicode(allocator);
    defer allocator.free(font_bytes);
    var text_engine = try shaping.Engine.init(font_bytes, sheet.body_font_size);
    defer text_engine.deinit();
    var run_cache = RunCache.init(allocator, &text_engine);
    defer run_cache.deinit();
    var glyph_engine = try rasterizer.Engine.init(
        allocator,
        font_bytes,
        sheet.body_font_size,
    );
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
    try surface.resize(900, 760);

    const document = try allocator.create(editing.Editor);
    defer allocator.destroy(document);
    document.* = .{};
    try document.setText("first\n \n");
    try renderer.paintEditor(
        &surface,
        document,
        &run_cache,
        &glyph_engine,
        1.0,
    );
    const full_frame = try allocator.dupe(u8, surface.pixels);
    defer allocator.free(full_frame);

    surface.paintSheet(1.0);
    try renderer.paintEditorContent(
        &surface,
        document,
        &run_cache,
        &glyph_engine,
        1.0,
    );
    try std.testing.expectEqualSlices(u8, full_frame, surface.pixels);

    const line_start = document.caretStopForOffset(6).?;
    const after_space = document.caretStopForOffset(7).?;
    const following_line = document.caretStopForOffset(8).?;
    try std.testing.expectEqual(line_start.row, after_space.row);
    try std.testing.expect(after_space.x > line_start.x);
    try std.testing.expectEqual(line_start.row + 1, following_line.row);
    try std.testing.expect(following_line.baseline > after_space.baseline);
}
