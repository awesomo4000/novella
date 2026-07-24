// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const novella = @import("novella");
const sheet = @import("sheet");
const editor = @import("editor");
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
    try paintDocumentInternal(surface, text, text.len, null, 0, run_cache, glyph_engine, scale);
}

pub fn paintEditorDocument(
    surface: *Surface,
    text: []const u8,
    cursor: usize,
    caret_map: *editor.CaretMap,
    revision: u64,
    run_cache: *RunCache,
    glyph_engine: *GlyphEngine,
    scale: f64,
) !void {
    try paintDocumentInternal(
        surface,
        text,
        @min(cursor, text.len),
        caret_map,
        revision,
        run_cache,
        glyph_engine,
        scale,
    );
}

fn paintDocumentInternal(
    surface: *Surface,
    text: []const u8,
    cursor: usize,
    caret_map: ?*editor.CaretMap,
    revision: u64,
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
    if (caret_map) |map| {
        map.begin();
        try map.add(.{ .offset = 0, .x = caret_x, .y = caret_y });
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
                    const word_start = paragraph_start + sliceOffset(paragraph, word.text);
                    const run = try run_cache.shape(word.text);
                    try recordWordCaretStops(
                        caret_map,
                        run,
                        word.text.len,
                        word_start,
                        x,
                        baseline,
                    );
                    try glyph_engine.drawRun(surface, run, x, baseline, sheet.ink);
                    x += word.width;
                    if (index + 1 < words.len and words[index + 1].space_before) {
                        const gap_end = paragraph_start + sliceOffset(paragraph, words[index + 1].text);
                        try recordGapCaretStops(
                            caret_map,
                            text,
                            word_start + word.text.len,
                            gap_end,
                            x,
                            baseline,
                            line.space_width,
                        );
                        x += line.space_width;
                    }
                }
                caret_x = x;
                caret_y = baseline;
                baseline += sheet.line_height * scale;
            }
            if (layout.words.len > 0) {
                const last_word = layout.words[layout.words.len - 1];
                const content_end = paragraph_start + sliceOffset(paragraph, last_word.text) + last_word.text.len;
                try recordTrailingCaretStops(
                    caret_map,
                    text,
                    content_end,
                    paragraph_end,
                    caret_x,
                    caret_y,
                    layout.natural_space_width,
                );
            } else {
                try recordTrailingCaretStops(
                    caret_map,
                    text,
                    paragraph_start,
                    paragraph_end,
                    caret_x,
                    caret_y,
                    layout.natural_space_width,
                );
            }
            baseline += sheet.paragraph_gap * scale;
        } else {
            try addCaretStop(caret_map, paragraph_start, geometry.content_left, baseline);
            if (separator != null)
                baseline += (sheet.line_height + sheet.paragraph_gap) * scale;
        }
        if (separator == null) break;
        try addCaretStop(caret_map, paragraph_end + 1, geometry.content_left, baseline);
        paragraph_start = paragraph_end + 1;
    }

    if (caret_map) |map| {
        if (map.stopForOffset(cursor)) |position| {
            caret_x = position.x;
            caret_y = position.y;
        }
        map.finish(revision);
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

fn addCaretStop(map: ?*editor.CaretMap, offset: usize, x: f64, y: f64) !void {
    if (map) |value| try value.add(.{ .offset = offset, .x = x, .y = y });
}

fn recordWordCaretStops(
    map: ?*editor.CaretMap,
    run: @import("text_engine").Run,
    source_len: usize,
    source_start: usize,
    x: f64,
    y: f64,
) !void {
    if (map == null) return;
    try addCaretStop(map, source_start, x, y);
    var pen_x: f64 = 0;
    var previous_cluster: ?u32 = null;
    for (run.glyphs) |glyph| {
        if (previous_cluster == null or previous_cluster.? != glyph.cluster) {
            const cluster: usize = @intCast(glyph.cluster);
            if (cluster <= source_len)
                try addCaretStop(map, source_start + cluster, x + pen_x, y);
            previous_cluster = glyph.cluster;
        }
        pen_x += glyph.x_advance;
    }
    try addCaretStop(map, source_start + source_len, x + run.advance, y);
}

fn recordGapCaretStops(
    map: ?*editor.CaretMap,
    source: []const u8,
    start: usize,
    end: usize,
    x: f64,
    y: f64,
    width: f64,
) !void {
    if (map == null or end <= start) return;
    var count: usize = 0;
    var cursor = start;
    while (cursor < end) : (count += 1) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(source[cursor]) catch 1;
        cursor = @min(end, cursor + @as(usize, @intCast(sequence_len)));
    }
    if (count == 0) return;

    try addCaretStop(map, start, x, y);
    cursor = start;
    var index: usize = 0;
    while (cursor < end) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(source[cursor]) catch 1;
        cursor = @min(end, cursor + @as(usize, @intCast(sequence_len)));
        index += 1;
        try addCaretStop(
            map,
            cursor,
            x + width * @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(count)),
            y,
        );
    }
}

fn recordTrailingCaretStops(
    map: ?*editor.CaretMap,
    source: []const u8,
    start: usize,
    end: usize,
    initial_x: f64,
    y: f64,
    space_width: f64,
) !void {
    if (map == null or end <= start) return;
    var x = initial_x;
    var cursor = start;
    try addCaretStop(map, cursor, x, y);
    while (cursor < end) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(source[cursor]) catch 1;
        cursor = @min(end, cursor + @as(usize, @intCast(sequence_len)));
        x += space_width;
        try addCaretStop(map, cursor, x, y);
    }
}

fn measureBodyText(context: ?*anyopaque, source: []const u8) f64 {
    const state = context orelse return 0;
    const run_cache: *RunCache = @ptrCast(@alignCast(state));
    const run = run_cache.shape(source) catch return 0;
    return run.advance;
}
