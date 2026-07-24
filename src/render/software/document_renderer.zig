// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const novella = @import("novella");
const sheet = @import("sheet");
const shaping = @import("text_engine");
const editing = @import("editor");
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
    try paint(surface, text, text.len, null, run_cache, glyph_engine, scale);
}

pub fn paintEditor(
    surface: *Surface,
    document: *editing.Editor,
    run_cache: *RunCache,
    glyph_engine: *GlyphEngine,
    scale: f64,
) !void {
    try paint(
        surface,
        document.text(),
        document.cursor,
        document,
        run_cache,
        glyph_engine,
        scale,
    );
}

fn paint(
    surface: *Surface,
    text: []const u8,
    cursor: usize,
    document: ?*editing.Editor,
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
    var caret_row: usize = 0;
    var row: usize = 0;
    if (document) |value| {
        value.beginCaretLayout();
        value.addCaretStop(0, caret_x, caret_y, row);
    }
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
                    const word_start =
                        paragraph_start + sliceOffset(paragraph, word.text);
                    const run = try run_cache.shape(word.text);
                    recordWordCaretStops(
                        document,
                        run,
                        word.text.len,
                        word_start,
                        x,
                        baseline,
                        row,
                    );
                    try glyph_engine.drawRun(surface, run, x, baseline, sheet.ink);
                    x += word.width;
                    if (index + 1 < words.len and words[index + 1].space_before) {
                        const gap_end = paragraph_start +
                            sliceOffset(paragraph, words[index + 1].text);
                        recordGapCaretStops(
                            document,
                            text,
                            word_start + word.text.len,
                            gap_end,
                            x,
                            baseline,
                            row,
                            line.space_width,
                        );
                        x += line.space_width;
                    }
                }
                caret_x = x;
                caret_y = baseline;
                caret_row = row;
                baseline += sheet.line_height * scale;
                row += 1;
            }
            if (layout.words.len > 0) {
                const last_word = layout.words[layout.words.len - 1];
                const content_end = paragraph_start +
                    sliceOffset(paragraph, last_word.text) + last_word.text.len;
                recordTrailingCaretStops(
                    document,
                    text,
                    content_end,
                    paragraph_end,
                    caret_x,
                    caret_y,
                    caret_row,
                    layout.natural_space_width,
                );
            } else {
                recordTrailingCaretStops(
                    document,
                    text,
                    paragraph_start,
                    paragraph_end,
                    caret_x,
                    caret_y,
                    caret_row,
                    layout.natural_space_width,
                );
            }
            baseline += sheet.paragraph_gap * scale;
        } else {
            if (document) |value|
                value.addCaretStop(paragraph_start, geometry.content_left, baseline, row);
            if (separator != null) {
                baseline += (sheet.line_height + sheet.paragraph_gap) * scale;
                row += 1;
            }
            caret_x = geometry.content_left;
            caret_y = baseline;
            caret_row = row;
        }
        if (separator == null) break;
        if (document) |value|
            value.addCaretStop(paragraph_end + 1, geometry.content_left, baseline, row);
        paragraph_start = paragraph_end + 1;
    }

    if (document) |value| {
        value.finishCaretLayout();
        if (value.caretStopForOffset(cursor)) |position| {
            caret_x = position.x;
            caret_y = position.baseline;
        }
    }
    surface.fillRect(.{
        .x = @intFromFloat(@round(caret_x - 2.0 * scale)),
        .y = @intFromFloat(@round(caret_y - 18.0 * scale)),
        .width = @intFromFloat(@round(2.0 * scale)),
        .height = @intFromFloat(@round(22.0 * scale)),
    }, sheet.caret);
}

fn sliceOffset(container: []const u8, part: []const u8) usize {
    return @intFromPtr(part.ptr) - @intFromPtr(container.ptr);
}

fn recordWordCaretStops(
    document: ?*editing.Editor,
    run: shaping.Run,
    source_len: usize,
    source_start: usize,
    x: f64,
    baseline: f64,
    row: usize,
) void {
    const value = document orelse return;
    value.addCaretStop(source_start, x, baseline, row);
    var pen_x: f64 = 0;
    var previous_cluster: ?u32 = null;
    for (run.glyphs) |glyph| {
        if (previous_cluster == null or previous_cluster.? != glyph.cluster) {
            const cluster: usize = @intCast(glyph.cluster);
            if (cluster <= source_len)
                value.addCaretStop(source_start + cluster, x + pen_x, baseline, row);
            previous_cluster = glyph.cluster;
        }
        pen_x += glyph.x_advance;
    }
    value.addCaretStop(source_start + source_len, x + run.advance, baseline, row);
}

fn recordGapCaretStops(
    document: ?*editing.Editor,
    source: []const u8,
    start: usize,
    end: usize,
    x: f64,
    baseline: f64,
    row: usize,
    width: f64,
) void {
    const value = document orelse return;
    if (end <= start) return;
    var count: usize = 0;
    var cursor = start;
    while (cursor < end) : (count += 1) {
        const sequence_len =
            std.unicode.utf8ByteSequenceLength(source[cursor]) catch 1;
        cursor = @min(end, cursor + @as(usize, @intCast(sequence_len)));
    }
    if (count == 0) return;

    value.addCaretStop(start, x, baseline, row);
    cursor = start;
    var index: usize = 0;
    while (cursor < end) {
        const sequence_len =
            std.unicode.utf8ByteSequenceLength(source[cursor]) catch 1;
        cursor = @min(end, cursor + @as(usize, @intCast(sequence_len)));
        index += 1;
        value.addCaretStop(
            cursor,
            x + width * @as(f64, @floatFromInt(index)) /
                @as(f64, @floatFromInt(count)),
            baseline,
            row,
        );
    }
}

fn recordTrailingCaretStops(
    document: ?*editing.Editor,
    source: []const u8,
    start: usize,
    end: usize,
    initial_x: f64,
    baseline: f64,
    row: usize,
    space_width: f64,
) void {
    const value = document orelse return;
    if (end <= start) return;
    var x = initial_x;
    var cursor = start;
    value.addCaretStop(cursor, x, baseline, row);
    while (cursor < end) {
        const sequence_len =
            std.unicode.utf8ByteSequenceLength(source[cursor]) catch 1;
        cursor = @min(end, cursor + @as(usize, @intCast(sequence_len)));
        x += space_width;
        value.addCaretStop(cursor, x, baseline, row);
    }
}

fn measureBodyText(context: ?*anyopaque, source: []const u8) f64 {
    const state = context orelse return 0;
    const run_cache: *RunCache = @ptrCast(@alignCast(state));
    const run = run_cache.shape(source) catch return 0;
    return run.advance;
}
