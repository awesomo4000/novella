// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const shaping = @import("text_engine");
const font_data = @import("font_data");

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
