// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const novella = @import("novella");

const Case = struct {
    name: []const u8,
    width: f64,
    text: []const u8,
};

// ASCII cases intentionally isolate the common core: caller measurement,
// boxes, flexible word glue, fitness classes, and paragraph-wide breaks.
const cases = [_]Case{
    .{ .name = "balanced", .width = 22, .text = "one two three four five six seven eight nine ten eleven twelve" },
    .{ .name = "uneven", .width = 27, .text = "a gathering storm moved quietly beyond the western ridge before morning" },
    .{ .name = "narrow", .width = 16, .text = "paper windows remember every room that silence leaves behind" },
    .{ .name = "punctuation", .width = 24, .text = "At first, the house waited; then the old stair answered softly." },
    .{ .name = "short-ending", .width = 30, .text = "The lamp burned late while rain crossed the garden and vanished." },
};

fn measureBytes(_: ?*anyopaque, text: []const u8) f64 {
    return @floatFromInt(text.len);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    const writer = &output.interface;

    for (cases) |case| {
        var layout = try novella.Layout.init(
            allocator,
            case.text,
            case.width,
            .{ .measure_fn = measureBytes },
            .{},
        );
        defer layout.deinit(allocator);

        try writer.print("{s}\t{d}\t", .{ case.name, layout.total_demerits });
        for (layout.lines, 0..) |line, line_index| {
            if (line_index > 0) try writer.writeByte(0x1f);
            for (layout.words[line.word_start..line.word_end], 0..) |word, word_index| {
                if (word_index > 0 and word.space_before) try writer.writeByte(' ');
                try writer.writeAll(word.text);
            }
        }
        try writer.writeByte('\t');
        for (layout.lines, 0..) |line, line_index| {
            if (line_index > 0) try writer.writeByte(',');
            if (std.math.isFinite(line.ratio)) {
                try writer.print("{d:.12}", .{line.ratio});
            } else if (line.ratio > 0) {
                try writer.writeAll("Infinity");
            } else {
                try writer.writeAll("-Infinity");
            }
        }
        try writer.writeByte('\n');
    }
    try writer.flush();
}
