// SPDX-License-Identifier: MPL-2.0 AND MIT

const std = @import("std");

/// TeX's "infinite" badness and forbidden-penalty sentinel.
pub const inf_bad: u32 = 10_000;

/// The four TeX fitness classes. Abrupt changes between adjacent classes are
/// discouraged even when each line would be acceptable in isolation.
pub const Fitness = enum(u2) {
    tight,
    decent,
    loose,
    very_loose,
};

/// TeX's integer approximation of 100 * (needed / available)^3.
///
/// This is ported from justif's DOM-free core, which in turn follows
/// TeX: The Program sections 108 and 834.
pub fn badness(needed: f64, available: f64) u32 {
    if (needed <= 0) return 0;
    if (available <= 0) return inf_bad;

    const ratio = @floor((297.0 * needed) / available);
    if (ratio > 1290.0) return inf_bad;
    return @intFromFloat(@floor((ratio * ratio * ratio + 131_072.0) / 262_144.0));
}

pub fn fitness(shrinking: bool, line_badness: u32) Fitness {
    if (line_badness <= 12) return .decent;
    if (shrinking) return .tight;
    return if (line_badness < 100) .loose else .very_loose;
}

/// Base demerits for a penalty-free line break.
pub fn lineDemerits(line_penalty: u32, line_badness: u32) u64 {
    const base = @as(u64, line_penalty) + line_badness;
    return if (base >= 10_000) 100_000_000 else base * base;
}

/// A font or rendering system supplies natural advances through this tiny
/// interface. The callback must remain valid only for the duration of
/// `Layout.init`.
pub const Measurer = struct {
    context: ?*anyopaque = null,
    measure_fn: *const fn (context: ?*anyopaque, utf8: []const u8) f64,

    pub fn width(self: Measurer, utf8: []const u8) f64 {
        return self.measure_fn(self.context, utf8);
    }
};

pub const Options = struct {
    /// Hyphen-free first-pass badness ceiling, matching TeX/justif.
    /// A negative value skips the first pass.
    pretolerance: i32 = 100,
    /// Maximum line badness accepted before the emergency pass.
    tolerance: u32 = 200,
    /// Base cost paid by every line.
    line_penalty: u32 = 10,
    /// Cost for a jump of more than one adjacent fitness class.
    adjacent_fitness_demerits: u32 = 10_000,
    /// Fraction of a natural word space available for stretching.
    space_stretch: f64 = 0.5,
    /// Fraction of a natural word space available for shrinking.
    space_shrink: f64 = 1.0 / 3.0,
    /// Absolute badness-only stretch used by the third pass. `null` follows
    /// justif's automatic value of twelve natural spaces (roughly 3 em).
    /// Set this to zero to disable the dedicated emergency-stretch pass.
    emergency_stretch: ?f64 = null,
    /// Maximum positive adjustment ratio that may be painted. More extreme
    /// rescue lines stay naturally spaced rather than opening visible chasms.
    max_rendered_stretch_ratio: f64 = 10.0,
};

pub const Word = struct {
    /// Slice of the caller-owned paragraph passed to `Layout.init`. Oversized
    /// tokens may be represented by multiple contiguous fragments.
    text: []const u8,
    width: f64,
    /// Whether collapsible source whitespace precedes this fragment. A false
    /// value after the first word marks a zero-width emergency wrap boundary.
    space_before: bool,
};

pub const Line = struct {
    /// Half-open range into `Layout.words`.
    word_start: usize,
    word_end: usize,
    natural_width: f64,
    target_width: f64,
    /// TeX adjustment ratio chosen by the paragraph optimizer.
    ratio: f64,
    /// Render every ordinary gap on this line at this width.
    space_width: f64,
    /// The final line stays ragged unless it is too wide for the measure.
    justified: bool,
    overfull: bool,

    pub fn renderedWidth(self: Line, words: []const Word) f64 {
        var result: f64 = 0;
        var gaps: usize = 0;
        for (words[self.word_start..self.word_end], 0..) |word, index| {
            result += word.width;
            if (index > 0 and word.space_before) gaps += 1;
        }
        return result + @as(f64, @floatFromInt(gaps)) * self.space_width;
    }
};

/// An owned layout whose word text slices still refer to the caller's input.
/// Keep that input alive until `deinit` (or until the words are no longer
/// inspected).
pub const Layout = struct {
    words: []Word,
    lines: []Line,
    natural_space_width: f64,
    total_demerits: u64,
    used_emergency_pass: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        paragraph: []const u8,
        target_width: f64,
        measurer: Measurer,
        options: Options,
    ) !Layout {
        if (!(target_width > 0) or !std.math.isFinite(target_width)) return error.InvalidWidth;
        if (options.space_stretch < 0 or options.space_shrink < 0) return error.InvalidFlex;
        if (options.emergency_stretch) |value| {
            if (value < 0 or !std.math.isFinite(value)) return error.InvalidFlex;
        }
        if (options.max_rendered_stretch_ratio < 0 or !std.math.isFinite(options.max_rendered_stretch_ratio))
            return error.InvalidFlex;

        var word_list: std.ArrayList(Word) = .empty;
        errdefer word_list.deinit(allocator);

        var cursor: usize = 0;
        while (cursor < paragraph.len) {
            while (cursor < paragraph.len and isCollapsibleSpace(paragraph[cursor])) cursor += 1;
            const start = cursor;
            while (cursor < paragraph.len and !isCollapsibleSpace(paragraph[cursor])) cursor += 1;
            if (start != cursor) {
                const text = paragraph[start..cursor];
                const width = measurer.width(text);
                if (width < 0 or !std.math.isFinite(width)) return error.InvalidMeasurement;
                try appendTokenFragments(
                    allocator,
                    &word_list,
                    text,
                    width,
                    target_width,
                    measurer,
                    word_list.items.len > 0,
                );
            }
        }

        const words = try word_list.toOwnedSlice(allocator);
        errdefer allocator.free(words);

        const natural_space = measurer.width(" ");
        if (natural_space < 0 or !std.math.isFinite(natural_space)) return error.InvalidMeasurement;
        if (words.len == 0) {
            return .{
                .words = words,
                .lines = try allocator.alloc(Line, 0),
                .natural_space_width = natural_space,
                .total_demerits = 0,
                .used_emergency_pass = false,
            };
        }

        const prefix = try allocator.alloc(f64, words.len + 1);
        defer allocator.free(prefix);
        const space_prefix = try allocator.alloc(usize, words.len + 1);
        defer allocator.free(space_prefix);
        prefix[0] = 0;
        space_prefix[0] = 0;
        for (words, 0..) |word, i| {
            prefix[i + 1] = prefix[i] + word.width;
            space_prefix[i + 1] = space_prefix[i] + @intFromBool(word.space_before);
        }

        const stretch = natural_space * options.space_stretch;
        const shrink = natural_space * options.space_shrink;
        const emergency_stretch = options.emergency_stretch orelse 12.0 * natural_space;

        var result: ?AttemptResult = null;
        if (options.pretolerance >= 0) {
            result = try attempt(
                allocator,
                words,
                prefix,
                space_prefix,
                target_width,
                natural_space,
                stretch,
                shrink,
                options,
                @intCast(options.pretolerance),
                0,
                false,
            );
        }
        if (result == null) {
            result = try attempt(
                allocator,
                words,
                prefix,
                space_prefix,
                target_width,
                natural_space,
                stretch,
                shrink,
                options,
                options.tolerance,
                0,
                false,
            );
        }
        var emergency = false;
        if (result == null and emergency_stretch > 0) {
            result = try attempt(
                allocator,
                words,
                prefix,
                space_prefix,
                target_width,
                natural_space,
                stretch,
                shrink,
                options,
                options.tolerance,
                emergency_stretch,
                false,
            );
            emergency = true;
        }
        if (result == null) {
            result = try attempt(
                allocator,
                words,
                prefix,
                space_prefix,
                target_width,
                natural_space,
                stretch,
                shrink,
                options,
                inf_bad,
                emergency_stretch,
                true,
            );
            emergency = true;
        }
        const solved = result orelse return error.NoLayout;
        return .{
            .words = words,
            .lines = solved.lines,
            .natural_space_width = natural_space,
            .total_demerits = solved.total_demerits,
            .used_emergency_pass = emergency,
        };
    }

    pub fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        allocator.free(self.words);
        allocator.free(self.lines);
        self.* = undefined;
    }
};

const State = struct {
    valid: bool = false,
    total_demerits: u64 = std.math.maxInt(u64),
    previous_position: usize = 0,
    previous_fitness: Fitness = .decent,
    ratio: f64 = 0,
    overfull: bool = false,
};

const AttemptResult = struct {
    lines: []Line,
    total_demerits: u64,
};

fn attempt(
    allocator: std.mem.Allocator,
    words: []const Word,
    prefix: []const f64,
    space_prefix: []const usize,
    target: f64,
    natural_space: f64,
    stretch_per_space: f64,
    shrink_per_space: f64,
    options: Options,
    tolerance: u32,
    extra_stretch: f64,
    rescue: bool,
) !?AttemptResult {
    const class_count = 4;
    const states = try allocator.alloc(State, (words.len + 1) * class_count);
    defer allocator.free(states);
    for (states) |*state| state.* = .{};
    stateAt(states, 0, .decent).valid = true;
    stateAt(states, 0, .decent).total_demerits = 0;

    for (1..words.len + 1) |end| {
        for (0..end) |start| {
            const gaps = interwordGapCount(words, space_prefix, start, end);
            const gap_count: f64 = @floatFromInt(gaps);
            const natural = prefix[end] - prefix[start] + gap_count * natural_space;
            const final_line = end == words.len;

            const needed = target - natural;
            const shrinking = needed < 0;
            const available = gap_count * (if (shrinking) shrink_per_space else stretch_per_space);
            const badness_available = available + (if (shrinking) 0 else extra_stretch);
            var ratio: f64 = 0;
            var line_badness: u32 = 0;
            var overfull = false;

            if (final_line and needed >= 0) {
                // TeX's parfillskip: a short final line has infinite-order
                // stretch, so it remains naturally spaced and costs nothing.
                ratio = 0;
            } else if (needed != 0) {
                ratio = if (available > 0) needed / available else if (needed > 0) std.math.inf(f64) else -std.math.inf(f64);
                overfull = ratio < -1;
                if (overfull and !rescue) continue;
                line_badness = badness(@abs(needed), badness_available);
                if (line_badness > tolerance) continue;
            }

            const current_fitness = fitness(shrinking, line_badness);
            for (std.enums.values(Fitness)) |previous_fitness| {
                const previous = stateAtConst(states, start, previous_fitness);
                if (!previous.valid) continue;

                var d = lineDemerits(options.line_penalty, line_badness);
                // In the rescue pass, any contained line is preferable to
                // text escaping the measure. Truly unbreakable glyphs still
                // get an overfull result because no contained route exists.
                if (overfull) d +|= @as(u64, 1) << 60;
                const fit_distance = @abs(@as(i8, @intCast(@intFromEnum(current_fitness))) - @as(i8, @intCast(@intFromEnum(previous_fitness))));
                if (fit_distance > 1) d +|= options.adjacent_fitness_demerits;
                const total = previous.total_demerits +| d;
                const destination = stateAt(states, end, current_fitness);
                if (!destination.valid or total < destination.total_demerits) {
                    destination.* = .{
                        .valid = true,
                        .total_demerits = total,
                        .previous_position = start,
                        .previous_fitness = previous_fitness,
                        .ratio = ratio,
                        .overfull = overfull,
                    };
                }
            }
        }
    }

    var best_fit: Fitness = .decent;
    var best: ?State = null;
    for (std.enums.values(Fitness)) |candidate_fit| {
        const candidate = stateAtConst(states, words.len, candidate_fit);
        if (candidate.valid and (best == null or candidate.total_demerits < best.?.total_demerits)) {
            best = candidate;
            best_fit = candidate_fit;
        }
    }
    const final_state = best orelse return null;

    var line_count: usize = 0;
    var position = words.len;
    var fit = best_fit;
    while (position > 0) : (line_count += 1) {
        const state = stateAtConst(states, position, fit);
        position = state.previous_position;
        fit = state.previous_fitness;
    }

    const lines = try allocator.alloc(Line, line_count);
    errdefer allocator.free(lines);
    position = words.len;
    fit = best_fit;
    var line_index = line_count;
    while (position > 0) {
        const state = stateAtConst(states, position, fit);
        const start = state.previous_position;
        const gaps = interwordGapCount(words, space_prefix, start, position);
        const gap_count: f64 = @floatFromInt(gaps);
        const natural = prefix[position] - prefix[start] + gap_count * natural_space;
        const final_line = position == words.len;
        const should_justify = (!final_line or natural > target) and
            state.ratio <= options.max_rendered_stretch_ratio;
        var rendered_space = natural_space;
        if (should_justify and gaps > 0 and std.math.isFinite(state.ratio)) {
            rendered_space += if (state.ratio >= 0)
                state.ratio * stretch_per_space
            else
                @max(state.ratio, -1.0) * shrink_per_space;
        }

        line_index -= 1;
        lines[line_index] = .{
            .word_start = start,
            .word_end = position,
            .natural_width = natural,
            .target_width = target,
            .ratio = state.ratio,
            .space_width = rendered_space,
            .justified = should_justify,
            .overfull = state.overfull,
        };
        position = start;
        fit = state.previous_fitness;
    }

    return .{ .lines = lines, .total_demerits = final_state.total_demerits };
}

fn stateAt(states: []State, position: usize, fit: Fitness) *State {
    return &states[position * 4 + @intFromEnum(fit)];
}

fn stateAtConst(states: []const State, position: usize, fit: Fitness) State {
    return states[position * 4 + @intFromEnum(fit)];
}

fn isCollapsibleSpace(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c => true,
        else => false,
    };
}

const FragmentBreak = struct {
    end: usize,
    width: f64,
};

fn appendTokenFragments(
    allocator: std.mem.Allocator,
    words: *std.ArrayList(Word),
    token: []const u8,
    token_width: f64,
    target_width: f64,
    measurer: Measurer,
    space_before: bool,
) !void {
    if (token_width <= target_width) {
        try words.append(allocator, .{
            .text = token,
            .width = token_width,
            .space_before = space_before,
        });
        return;
    }

    var start: usize = 0;
    var first = true;
    while (start < token.len) {
        const remainder = token[start..];
        const remainder_width = measurer.width(remainder);
        if (remainder_width < 0 or !std.math.isFinite(remainder_width))
            return error.InvalidMeasurement;

        const fragment = if (remainder_width <= target_width)
            FragmentBreak{ .end = token.len, .width = remainder_width }
        else blk: {
            const hard = try hardFragmentBreak(allocator, remainder, target_width, measurer);
            var soft_end: usize = 0;
            var cursor: usize = 0;
            while (cursor < hard.end) {
                const next = nextUtf8Boundary(remainder, cursor);
                if (next <= hard.end and isPreferredWrapByte(remainder[cursor])) soft_end = next;
                cursor = next;
            }
            if (soft_end > 0) {
                const soft_width = measurer.width(remainder[0..soft_end]);
                if (soft_width < 0 or !std.math.isFinite(soft_width))
                    return error.InvalidMeasurement;
                // Prefer nearby URL and identifier punctuation, but do not
                // leave a tiny fragment merely to avoid an arbitrary wrap.
                if (soft_width >= hard.width * 0.7)
                    break :blk FragmentBreak{ .end = start + soft_end, .width = soft_width };
            }
            break :blk FragmentBreak{ .end = start + hard.end, .width = hard.width };
        };

        if (fragment.end <= start) return error.InvalidMeasurement;
        try words.append(allocator, .{
            .text = token[start..fragment.end],
            .width = fragment.width,
            .space_before = first and space_before,
        });
        first = false;
        start = fragment.end;
    }
}

fn hardFragmentBreak(
    allocator: std.mem.Allocator,
    text: []const u8,
    target_width: f64,
    measurer: Measurer,
) !FragmentBreak {
    var boundaries: std.ArrayList(usize) = .empty;
    defer boundaries.deinit(allocator);

    var cursor: usize = 0;
    while (cursor < text.len) {
        cursor = nextUtf8Boundary(text, cursor);
        try boundaries.append(allocator, cursor);
    }

    var low: usize = 0;
    var high: usize = boundaries.items.len;
    var best: ?FragmentBreak = null;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const end = boundaries.items[middle];
        const width = measurer.width(text[0..end]);
        if (width < 0 or !std.math.isFinite(width)) return error.InvalidMeasurement;
        if (width <= target_width) {
            best = .{ .end = end, .width = width };
            low = middle + 1;
        } else {
            high = middle;
        }
    }

    if (best) |result| return result;
    const first_end = boundaries.items[0];
    const first_width = measurer.width(text[0..first_end]);
    if (first_width < 0 or !std.math.isFinite(first_width)) return error.InvalidMeasurement;
    return .{ .end = first_end, .width = first_width };
}

fn nextUtf8Boundary(text: []const u8, start: usize) usize {
    const sequence_len = std.unicode.utf8ByteSequenceLength(text[start]) catch 1;
    return @min(text.len, start + @as(usize, @intCast(sequence_len)));
}

fn isPreferredWrapByte(byte: u8) bool {
    return switch (byte) {
        '/', '-', '.', '?', '&', '=', '#', '_', ':', '~', '%', '+' => true,
        else => false,
    };
}

fn interwordGapCount(words: []const Word, prefix: []const usize, start: usize, end: usize) usize {
    var result = prefix[end] - prefix[start];
    if (words[start].space_before) result -= 1;
    return result;
}

fn monospaceMeasure(_: ?*anyopaque, text: []const u8) f64 {
    return @floatFromInt(text.len);
}

test "badness matches TeX canonical values" {
    try std.testing.expectEqual(@as(u32, 100), badness(1, 1));
    try std.testing.expectEqual(@as(u32, 12), badness(0.5, 1));
    try std.testing.expectEqual(@as(u32, 1), badness(0.2, 1));
    try std.testing.expectEqual(@as(u32, 0), badness(0, 1));
    try std.testing.expectEqual(inf_bad, badness(1, 0));
    try std.testing.expectEqual(inf_bad, badness(4.35, 1));
}

test "fitness follows TeX boundaries" {
    try std.testing.expectEqual(Fitness.decent, fitness(false, 12));
    try std.testing.expectEqual(Fitness.loose, fitness(false, 13));
    try std.testing.expectEqual(Fitness.tight, fitness(true, 13));
    try std.testing.expectEqual(Fitness.very_loose, fitness(false, 100));
}

test "layout returns render-ready justified lines" {
    const allocator = std.testing.allocator;
    var layout = try Layout.init(
        allocator,
        "one two three four five six seven eight nine ten",
        18,
        .{ .measure_fn = monospaceMeasure },
        .{ .space_stretch = 1.0, .space_shrink = 1.0 },
    );
    defer layout.deinit(allocator);

    try std.testing.expect(layout.lines.len >= 2);
    for (layout.lines[0 .. layout.lines.len - 1]) |line| {
        try std.testing.expect(line.justified);
        try std.testing.expectApproxEqAbs(line.target_width, line.renderedWidth(layout.words), 0.000_001);
    }
    try std.testing.expect(!layout.lines[layout.lines.len - 1].justified);
}

test "emergency stretch selects breaks without changing painted width" {
    const allocator = std.testing.allocator;
    var layout = try Layout.init(
        allocator,
        "aa aa aa aa aa",
        7,
        .{ .measure_fn = monospaceMeasure },
        .{},
    );
    defer layout.deinit(allocator);

    try std.testing.expect(layout.used_emergency_pass);
    try std.testing.expectEqual(@as(usize, 2), layout.lines[0].word_end);
    try std.testing.expectApproxEqAbs(@as(f64, 4), layout.lines[0].ratio, 0.000_001);
    try std.testing.expectApproxEqAbs(@as(f64, 7), layout.lines[0].renderedWidth(layout.words), 0.000_001);
}

test "oversized tokens wrap without inserting spaces" {
    const allocator = std.testing.allocator;
    const source = "https://somedomain-idontknow.com/this/that/theotherthing/query/tothewordsyouwanttogo";
    var layout = try Layout.init(
        allocator,
        source,
        24,
        .{ .measure_fn = monospaceMeasure },
        .{},
    );
    defer layout.deinit(allocator);

    try std.testing.expect(layout.words.len > 1);
    try std.testing.expect(layout.lines.len > 1);
    var reconstructed: std.ArrayList(u8) = .empty;
    defer reconstructed.deinit(allocator);
    for (layout.words) |word| {
        try std.testing.expect(!word.space_before);
        try reconstructed.appendSlice(allocator, word.text);
    }
    try std.testing.expectEqualStrings(source, reconstructed.items);
    for (layout.lines) |line| {
        try std.testing.expect(!line.overfull);
        try std.testing.expect(line.renderedWidth(layout.words) <= line.target_width + 0.000_001);
    }
}

test "rescue prefers a ragged break over an overfull final line" {
    const allocator = std.testing.allocator;
    const source = "one two aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    var layout = try Layout.init(
        allocator,
        source,
        40,
        .{ .measure_fn = monospaceMeasure },
        .{},
    );
    defer layout.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), layout.lines.len);
    try std.testing.expect(!layout.lines[0].justified);
    for (layout.lines) |line| {
        try std.testing.expect(!line.overfull);
        try std.testing.expect(line.renderedWidth(layout.words) <= line.target_width + 0.000_001);
    }
}

test "whitespace-only paragraphs produce no lines" {
    const allocator = std.testing.allocator;
    var layout = try Layout.init(
        allocator,
        " \n\t ",
        20,
        .{ .measure_fn = monospaceMeasure },
        .{},
    );
    defer layout.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), layout.words.len);
    try std.testing.expectEqual(@as(usize, 0), layout.lines.len);
}
