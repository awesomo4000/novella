// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const novella = @import("novella");
const shaping = @import("text_engine");
const font_data = @import("font_data");

fn harfbuzzMeasure(context: ?*anyopaque, text: []const u8) f64 {
    const engine: *const shaping.Engine = @ptrCast(@alignCast(context.?));
    var run = engine.shape(std.heap.smp_allocator, text) catch return std.math.nan(f64);
    defer run.deinit(std.heap.smp_allocator);
    return run.advance;
}

test "Junicode shaping is deterministic" {
    const allocator = std.testing.allocator;
    const font_bytes = try font_data.loadJunicode(allocator);
    defer allocator.free(font_bytes);

    var engine = try shaping.Engine.init(font_bytes, 18.5);
    defer engine.deinit();

    var run = try engine.shape(allocator, "office AVATAR café");
    defer run.deinit(allocator);

    const Expected = struct { id: u32, cluster: u32, advance: i32 };
    const expected = [_]Expected{
        .{ .id = 901, .cluster = 0, .advance = 547 },
        .{ .id = 1516, .cluster = 1, .advance = 309 },
        .{ .id = 1432, .cluster = 2, .advance = 337 },
        .{ .id = 1425, .cluster = 3, .advance = 263 },
        .{ .id = 713, .cluster = 4, .advance = 466 },
        .{ .id = 741, .cluster = 5, .advance = 475 },
        .{ .id = 3718, .cluster = 6, .advance = 288 },
        .{ .id = 1, .cluster = 7, .advance = 694 },
        .{ .id = 350, .cluster = 8, .advance = 600 },
        .{ .id = 1, .cluster = 9, .advance = 754 },
        .{ .id = 300, .cluster = 10, .advance = 708 },
        .{ .id = 1, .cluster = 11, .advance = 810 },
        .{ .id = 273, .cluster = 12, .advance = 816 },
        .{ .id = 3718, .cluster = 13, .advance = 288 },
        .{ .id = 713, .cluster = 14, .advance = 480 },
        .{ .id = 663, .cluster = 15, .advance = 472 },
        .{ .id = 1248, .cluster = 16, .advance = 336 },
        .{ .id = 742, .cluster = 17, .advance = 475 },
    };
    try std.testing.expectEqual(expected.len, run.glyphs.len);
    try std.testing.expectEqual(@as(i32, 9118), @as(i32, @intFromFloat(@round(run.advance * 64.0))));
    for (expected, run.glyphs) |wanted, glyph| {
        try std.testing.expectEqual(wanted.id, glyph.id);
        try std.testing.expectEqual(wanted.cluster, glyph.cluster);
        try std.testing.expectEqual(
            wanted.advance,
            @as(i32, @intFromFloat(@round(glyph.x_advance * 64.0))),
        );
        try std.testing.expectEqual(@as(f64, 0), glyph.y_advance);
        try std.testing.expectEqual(@as(f64, 0), glyph.x_offset);
        try std.testing.expectEqual(@as(f64, 0), glyph.y_offset);
    }
}

test "combining marks share a HarfBuzz caret cluster" {
    const allocator = std.testing.allocator;
    const font_bytes = try font_data.loadJunicode(allocator);
    defer allocator.free(font_bytes);

    var engine = try shaping.Engine.init(font_bytes, 18.5);
    defer engine.deinit();

    var run = try engine.shape(allocator, "a\u{301}b");
    defer run.deinit(allocator);

    try std.testing.expect(run.glyphs.len >= 2);
    try std.testing.expectEqual(@as(u32, 0), run.glyphs[0].cluster);
    try std.testing.expectEqual(@as(u32, 3), run.glyphs[1].cluster);
}

test "resizing does not create a chasm between two words" {
    const allocator = std.testing.allocator;
    const font_bytes = try font_data.loadJunicode(allocator);
    defer allocator.free(font_bytes);

    var engine = try shaping.Engine.init(font_bytes, 18.5);
    defer engine.deinit();

    const paragraph = "The text breaks use a justification algorithm that makes the browser text \"pretty\" justification look like it was created by monkeys. Only Knuth knows the true way to get typeset quality in text. Don't fuck with Knuth.";
    var maximum_space: f64 = 0;
    var width: f64 = 224.0;
    while (width <= 498.0) : (width += 0.5) {
        var layout = try novella.Layout.init(
            allocator,
            paragraph,
            width,
            .{ .context = &engine, .measure_fn = harfbuzzMeasure },
            .{},
        );
        defer layout.deinit(allocator);

        for (layout.lines) |line| {
            if (line.justified and line.space_width > maximum_space) {
                maximum_space = line.space_width;
            }
            if (!line.justified or line.word_end - line.word_start != 2) continue;
            const first = layout.words[line.word_start].text;
            const second = layout.words[line.word_start + 1].text;
            if (std.mem.eql(u8, first, "The") and std.mem.eql(u8, second, "text")) {
                return error.TwoWordChasm;
            }
        }
    }
    try std.testing.expect(maximum_space <= 6.0 * harfbuzzMeasure(&engine, " "));
}
