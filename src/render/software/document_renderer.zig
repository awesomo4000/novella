// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const novella = @import("novella");
const sheet = @import("sheet");
const GlyphEngine = @import("freetype.zig").Engine;
const RunCache = @import("run_cache.zig").RunCache;
const Surface = @import("surface.zig").Surface;

pub fn paintDocument(
    surface: *Surface,
    text: []const u8,
    run_cache: *RunCache,
    glyph_engine: *GlyphEngine,
    scale: f64,
) !void {
    surface.paintSheet(scale);
    const geometry = sheet.scaledGeometry(surface.width, surface.height, scale);
    var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer scratch.deinit();
    const allocator = scratch.allocator();

    var baseline = geometry.first_baseline_top;
    var caret_x = geometry.content_left;
    var caret_y = baseline;
    var paragraph_start: usize = 0;
    while (paragraph_start <= text.len) {
        const rest = text[paragraph_start..];
        const separator = std.mem.indexOfScalar(u8, rest, '\n');
        const paragraph_end = if (separator) |offset| paragraph_start + offset else text.len;
        const paragraph = text[paragraph_start..paragraph_end];
        if (paragraph.len > 0) {
            var layout = try novella.Layout.init(
                allocator,
                paragraph,
                geometry.measure_width,
                .{ .context = run_cache, .measure_fn = measureBodyText },
                .{},
            );
            defer layout.deinit(allocator);

            for (layout.lines) |line| {
                if (baseline > geometry.paper_top + geometry.paper_height - 62.0 * scale) break;
                var x = geometry.content_left;
                const words = layout.words[line.word_start..line.word_end];
                for (words, 0..) |word, index| {
                    const run = try run_cache.shape(word.text);
                    try glyph_engine.drawRun(surface, run, x, baseline, sheet.ink);
                    x += word.width;
                    if (index + 1 < words.len and words[index + 1].space_before)
                        x += line.space_width;
                }
                caret_x = x;
                caret_y = baseline;
                baseline += sheet.line_height * scale;
            }
            baseline += sheet.paragraph_gap * scale;
        } else if (separator != null) {
            baseline += (sheet.line_height + sheet.paragraph_gap) * scale;
            caret_x = geometry.content_left;
            caret_y = baseline;
        }
        if (separator == null) break;
        paragraph_start = paragraph_end + 1;
    }

    surface.fillRect(.{
        .x = @intFromFloat(@round(caret_x - 2.0 * scale)),
        .y = @intFromFloat(@round(caret_y - 18.0 * scale)),
        .width = @intFromFloat(@round(2.0 * scale)),
        .height = @intFromFloat(@round(22.0 * scale)),
    }, sheet.caret);
}

fn measureBodyText(context: ?*anyopaque, source: []const u8) f64 {
    const state = context orelse return 0;
    const run_cache: *RunCache = @ptrCast(@alignCast(state));
    const run = run_cache.shape(source) catch return 0;
    return run.advance;
}
