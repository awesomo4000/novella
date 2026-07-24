// SPDX-License-Identifier: MPL-2.0

const std = @import("std");

const minimum_capacity: usize = 64;

pub const Document = struct {
    allocator: std.mem.Allocator,
    storage: []u8,
    gap_start: usize,
    gap_end: usize,
    cursor: usize,
    revision: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, initial_text: []const u8) !Document {
        const normalized = try normalizeUtf8(allocator, initial_text);
        defer allocator.free(normalized);

        const spare = try std.math.add(usize, normalized.len / 2, 1);
        const requested = try std.math.add(usize, normalized.len, spare);
        const capacity = @max(minimum_capacity, requested);
        const storage = try allocator.alloc(u8, capacity);
        errdefer allocator.free(storage);
        @memcpy(storage[0..normalized.len], normalized);

        return .{
            .allocator = allocator,
            .storage = storage,
            .gap_start = normalized.len,
            .gap_end = storage.len,
            .cursor = normalized.len,
        };
    }

    pub fn deinit(self: *Document) void {
        self.allocator.free(self.storage);
        self.* = undefined;
    }

    pub fn len(self: *const Document) usize {
        return self.storage.len - (self.gap_end - self.gap_start);
    }

    /// Returns a contiguous view that remains valid until the next mutation.
    pub fn text(self: *Document) []const u8 {
        const text_len = self.len();
        self.moveGap(text_len);
        return self.storage[0..text_len];
    }

    pub fn setCursor(self: *Document, position: usize) !void {
        if (!self.isCodepointBoundary(position)) return error.InvalidTextBoundary;
        self.cursor = position;
    }

    pub fn previousCodepoint(self: *const Document, position: usize) usize {
        if (position == 0) return 0;
        var result = @min(position, self.len()) - 1;
        while (result > 0 and (self.byteAt(result) & 0xc0) == 0x80) result -= 1;
        return result;
    }

    pub fn nextCodepoint(self: *const Document, position: usize) usize {
        if (position >= self.len()) return self.len();
        const sequence_len = std.unicode.utf8ByteSequenceLength(self.byteAt(position)) catch 1;
        return @min(self.len(), position + @as(usize, @intCast(sequence_len)));
    }

    pub fn insertUtf8(self: *Document, source: []const u8) !bool {
        return self.insertRepeatedUtf8(source, 1);
    }

    pub fn insertRepeatedUtf8(
        self: *Document,
        source: []const u8,
        requested_count: usize,
    ) !bool {
        if (requested_count == 0) return false;
        const normalized = try normalizeUtf8(self.allocator, source);
        defer self.allocator.free(normalized);
        if (normalized.len == 0) return false;

        const added_len = try std.math.mul(usize, normalized.len, requested_count);

        self.moveGap(self.cursor);
        try self.ensureGap(added_len);
        var destination = self.gap_start;
        for (0..requested_count) |_| {
            @memcpy(self.storage[destination .. destination + normalized.len], normalized);
            destination += normalized.len;
        }
        self.gap_start += added_len;
        self.cursor += added_len;
        self.markChanged();
        return true;
    }

    pub fn deleteRange(self: *Document, start: usize, end: usize) !bool {
        if (start > end or end > self.len()) return error.InvalidTextRange;
        if (!self.isCodepointBoundary(start) or !self.isCodepointBoundary(end))
            return error.InvalidTextBoundary;
        if (start == end) return false;

        self.moveGap(start);
        self.gap_end += end - start;
        self.cursor = start;
        self.markChanged();
        return true;
    }

    fn markChanged(self: *Document) void {
        self.revision +%= 1;
        if (self.revision == 0) self.revision = 1;
    }

    fn gapLen(self: *const Document) usize {
        return self.gap_end - self.gap_start;
    }

    fn byteAt(self: *const Document, position: usize) u8 {
        std.debug.assert(position < self.len());
        if (position < self.gap_start) return self.storage[position];
        return self.storage[position + self.gapLen()];
    }

    fn isCodepointBoundary(self: *const Document, position: usize) bool {
        if (position > self.len()) return false;
        if (position == 0 or position == self.len()) return true;
        return (self.byteAt(position) & 0xc0) != 0x80;
    }

    fn moveGap(self: *Document, position: usize) void {
        std.debug.assert(position <= self.len());
        if (position < self.gap_start) {
            const count = self.gap_start - position;
            std.mem.copyBackwards(
                u8,
                self.storage[self.gap_end - count .. self.gap_end],
                self.storage[position..self.gap_start],
            );
            self.gap_start = position;
            self.gap_end -= count;
        } else if (position > self.gap_start) {
            const count = position - self.gap_start;
            std.mem.copyForwards(
                u8,
                self.storage[self.gap_start .. self.gap_start + count],
                self.storage[self.gap_end .. self.gap_end + count],
            );
            self.gap_start += count;
            self.gap_end += count;
        }
    }

    fn ensureGap(self: *Document, required: usize) !void {
        if (self.gapLen() >= required) return;

        const text_len = self.len();
        const minimum = try std.math.add(usize, text_len, required);
        const doubled = std.math.mul(usize, self.storage.len, 2) catch minimum;
        const new_capacity = @max(minimum, doubled, minimum_capacity);
        const replacement = try self.allocator.alloc(u8, new_capacity);
        errdefer self.allocator.free(replacement);

        @memcpy(replacement[0..self.gap_start], self.storage[0..self.gap_start]);
        const suffix_len = self.storage.len - self.gap_end;
        const new_gap_end = replacement.len - suffix_len;
        @memcpy(replacement[new_gap_end..], self.storage[self.gap_end..]);

        self.allocator.free(self.storage);
        self.storage = replacement;
        self.gap_end = new_gap_end;
    }
};

fn normalizeUtf8(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidUtf8;

    var normalized_len: usize = 0;
    var source_index: usize = 0;
    while (source_index < source.len) : (source_index += 1) {
        normalized_len += 1;
        if (source[source_index] == '\r' and
            source_index + 1 < source.len and source[source_index + 1] == '\n')
            source_index += 1;
    }

    const normalized = try allocator.alloc(u8, normalized_len);
    var destination_index: usize = 0;
    source_index = 0;
    while (source_index < source.len) : (source_index += 1) {
        if (source[source_index] == '\r') {
            normalized[destination_index] = '\n';
            if (source_index + 1 < source.len and source[source_index + 1] == '\n')
                source_index += 1;
        } else {
            normalized[destination_index] = source[source_index];
        }
        destination_index += 1;
    }
    return normalized;
}

test "document normalizes paragraph separators and starts at the end" {
    var document = try Document.init(std.testing.allocator, "one\r\n\rtwo");
    defer document.deinit();

    try std.testing.expectEqualStrings("one\n\ntwo", document.text());
    try std.testing.expectEqual(document.len(), document.cursor);
}

test "gap buffer inserts and deletes in the middle" {
    var document = try Document.init(std.testing.allocator, "ac");
    defer document.deinit();

    try document.setCursor(1);
    try std.testing.expect(try document.insertUtf8("b"));
    try std.testing.expectEqualStrings("abc", document.text());
    try std.testing.expectEqual(@as(usize, 2), document.cursor);

    try std.testing.expect(try document.deleteRange(1, 2));
    try std.testing.expectEqualStrings("ac", document.text());
    try std.testing.expectEqual(@as(usize, 1), document.cursor);
}

test "UTF-8 cursor operations preserve codepoint boundaries" {
    var document = try Document.init(std.testing.allocator, "aéz");
    defer document.deinit();

    try std.testing.expectError(error.InvalidTextBoundary, document.setCursor(2));
    try std.testing.expectEqual(@as(usize, 1), document.previousCodepoint(3));
    try std.testing.expectEqual(@as(usize, 3), document.nextCodepoint(1));
    try std.testing.expectError(error.InvalidUtf8, document.insertUtf8("\xff"));
    try std.testing.expectEqualStrings("aéz", document.text());
}

test "trailing Returns are deleted one at a time" {
    var document = try Document.init(std.testing.allocator, "end");
    defer document.deinit();

    try std.testing.expect(try document.insertUtf8("\n\n\n"));
    try std.testing.expect(try document.deleteRange(document.previousCodepoint(document.cursor), document.cursor));
    try std.testing.expectEqualStrings("end\n\n", document.text());
    try std.testing.expect(try document.deleteRange(document.previousCodepoint(document.cursor), document.cursor));
    try std.testing.expectEqualStrings("end\n", document.text());
    try std.testing.expect(try document.deleteRange(document.previousCodepoint(document.cursor), document.cursor));
    try std.testing.expectEqualStrings("end", document.text());
}

test "repeated insertion grows and shifts the gap once" {
    var document = try Document.init(std.testing.allocator, "ac");
    defer document.deinit();

    try document.setCursor(1);
    try std.testing.expect(try document.insertRepeatedUtf8("b", 4));
    try std.testing.expectEqualStrings("abbbbc", document.text());
    try std.testing.expectEqual(@as(usize, 5), document.cursor);
}
