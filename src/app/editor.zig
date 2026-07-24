// SPDX-License-Identifier: MPL-2.0

const std = @import("std");

pub const max_text_bytes = 64 * 1024;

pub const Direction = enum {
    up,
    down,
};

pub const CaretStop = struct {
    offset: usize,
    x: f64,
    baseline: f64,
    row: usize,
};

pub const Editor = struct {
    bytes: [max_text_bytes]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,
    preferred_x: f64 = 0,
    preferred_x_active: bool = false,
    caret_stops: [max_text_bytes + 1]CaretStop = undefined,
    caret_stop_count: usize = 0,
    document_revision: u64 = 1,
    caret_revision: u64 = 0,

    pub fn setText(self: *Editor, source_text: []const u8) !void {
        if (source_text.len > self.bytes.len) return error.InputTooLong;
        if (!std.unicode.utf8ValidateSlice(source_text)) return error.InvalidUtf8;

        var source: usize = 0;
        var destination: usize = 0;
        while (source < source_text.len) : (source += 1) {
            if (source_text[source] == '\r') {
                self.bytes[destination] = '\n';
                destination += 1;
                if (source + 1 < source_text.len and source_text[source + 1] == '\n') source += 1;
            } else {
                self.bytes[destination] = source_text[source];
                destination += 1;
            }
        }
        self.len = destination;
        self.cursor = destination;
        self.preferred_x_active = false;
        self.caret_stop_count = 0;
        self.document_revision = 1;
        self.caret_revision = 0;
    }

    pub fn text(self: *const Editor) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn insert(self: *Editor, value: []const u8) bool {
        return self.insertRepeated(value, 1);
    }

    pub fn insertRepeated(
        self: *Editor,
        value: []const u8,
        requested_count: usize,
    ) bool {
        if (value.len == 0 or requested_count == 0) return false;
        if (!std.unicode.utf8ValidateSlice(value)) return false;
        const count = @min(requested_count, (self.bytes.len - self.len) / value.len);
        if (count == 0) return false;

        const old_len = self.len;
        const added_len = value.len * count;
        const new_len = old_len + added_len;
        std.mem.copyBackwards(
            u8,
            self.bytes[self.cursor + added_len .. new_len],
            self.bytes[self.cursor..old_len],
        );
        var destination = self.cursor;
        for (0..count) |_| {
            @memcpy(self.bytes[destination .. destination + value.len], value);
            destination += value.len;
        }
        self.cursor += added_len;
        self.len = new_len;
        self.preferred_x_active = false;
        self.markChanged();
        return true;
    }

    pub fn insertLineBreak(self: *Editor) bool {
        return self.insert("\n");
    }

    pub fn backspace(self: *Editor) bool {
        if (self.cursor == 0) return false;
        self.deleteRange(self.previousCaretBoundary(self.cursor), self.cursor);
        self.preferred_x_active = false;
        return true;
    }

    pub fn deleteForward(self: *Editor) bool {
        if (self.cursor >= self.len) return false;
        self.deleteRange(self.cursor, self.nextCaretBoundary(self.cursor));
        self.preferred_x_active = false;
        return true;
    }

    pub fn moveLeft(self: *Editor) bool {
        const previous = self.previousCaretBoundary(self.cursor);
        const changed = previous != self.cursor;
        self.cursor = previous;
        self.preferred_x_active = false;
        return changed;
    }

    pub fn moveRight(self: *Editor) bool {
        const next = self.nextCaretBoundary(self.cursor);
        const changed = next != self.cursor;
        self.cursor = next;
        self.preferred_x_active = false;
        return changed;
    }

    pub fn moveVertical(self: *Editor, direction: Direction) bool {
        if (self.caret_revision != self.document_revision) return false;
        const current = self.caretStopForOffset(self.cursor) orelse return false;
        const target_row = switch (direction) {
            .up => if (current.row == 0) return false else current.row - 1,
            .down => current.row + 1,
        };
        if (!self.preferred_x_active) {
            self.preferred_x = current.x;
            self.preferred_x_active = true;
        }

        var best: ?CaretStop = null;
        var best_distance = std.math.inf(f64);
        for (self.caret_stops[0..self.caret_stop_count]) |stop| {
            if (stop.row != target_row) continue;
            const distance = @abs(stop.x - self.preferred_x);
            if (distance < best_distance) {
                best = stop;
                best_distance = distance;
            }
        }
        const target = best orelse return false;
        const changed = target.offset != self.cursor;
        self.cursor = target.offset;
        return changed;
    }

    pub fn beginCaretLayout(self: *Editor) void {
        self.caret_stop_count = 0;
        self.caret_revision = 0;
    }

    pub fn addCaretStop(
        self: *Editor,
        offset: usize,
        x: f64,
        baseline: f64,
        row: usize,
    ) void {
        if (self.caret_stop_count > 0) {
            const previous = &self.caret_stops[self.caret_stop_count - 1];
            if (previous.offset == offset) {
                previous.* = .{
                    .offset = offset,
                    .x = x,
                    .baseline = baseline,
                    .row = row,
                };
                return;
            }
        }
        if (self.caret_stop_count >= self.caret_stops.len) return;
        self.caret_stops[self.caret_stop_count] = .{
            .offset = offset,
            .x = x,
            .baseline = baseline,
            .row = row,
        };
        self.caret_stop_count += 1;
    }

    pub fn finishCaretLayout(self: *Editor) void {
        self.caret_revision = self.document_revision;
    }

    pub fn caretStopForOffset(self: *const Editor, offset: usize) ?CaretStop {
        var nearest: ?CaretStop = null;
        for (self.caret_stops[0..self.caret_stop_count]) |stop| {
            if (stop.offset == offset) return stop;
            if (stop.offset < offset and
                (nearest == null or stop.offset > nearest.?.offset))
            {
                nearest = stop;
            }
        }
        return nearest;
    }

    fn previousCaretBoundary(self: *const Editor, position: usize) usize {
        if (self.caret_revision != self.document_revision)
            return self.previousCodepoint(position);

        var previous: ?usize = null;
        var found = false;
        for (self.caret_stops[0..self.caret_stop_count]) |stop| {
            if (stop.offset == position) found = true;
            if (stop.offset < position and
                (previous == null or stop.offset > previous.?))
            {
                previous = stop.offset;
            }
        }
        return if (found) previous orelse 0 else self.previousCodepoint(position);
    }

    fn nextCaretBoundary(self: *const Editor, position: usize) usize {
        if (self.caret_revision != self.document_revision)
            return self.nextCodepoint(position);

        var next: ?usize = null;
        var found = false;
        for (self.caret_stops[0..self.caret_stop_count]) |stop| {
            if (stop.offset == position) found = true;
            if (stop.offset > position and (next == null or stop.offset < next.?))
                next = stop.offset;
        }
        return if (found) next orelse self.len else self.nextCodepoint(position);
    }

    fn previousCodepoint(self: *const Editor, position: usize) usize {
        if (position == 0) return 0;
        var result = position - 1;
        while (result > 0 and (self.bytes[result] & 0xc0) == 0x80) result -= 1;
        return result;
    }

    fn nextCodepoint(self: *const Editor, position: usize) usize {
        if (position >= self.len) return self.len;
        const sequence_len =
            std.unicode.utf8ByteSequenceLength(self.bytes[position]) catch 1;
        return @min(self.len, position + @as(usize, @intCast(sequence_len)));
    }

    fn deleteRange(self: *Editor, start: usize, end: usize) void {
        if (start >= end or end > self.len) return;
        const count = end - start;
        std.mem.copyForwards(
            u8,
            self.bytes[start .. self.len - count],
            self.bytes[end..self.len],
        );
        self.len -= count;
        self.cursor = start;
        self.markChanged();
    }

    fn markChanged(self: *Editor) void {
        self.document_revision +%= 1;
        if (self.document_revision == 0) self.document_revision = 1;
    }
};

test "initial text normalizes each CR and CRLF to one line feed" {
    var editor: Editor = .{};
    try editor.setText("one\r\ntwo\rthree\nfour");
    try std.testing.expectEqualStrings("one\ntwo\nthree\nfour", editor.text());
    try std.testing.expectEqual(editor.text().len, editor.cursor);
}

test "line breaks insert and delete one visual paragraph boundary at a time" {
    var editor: Editor = .{};
    try editor.setText("a");
    try std.testing.expect(editor.insertLineBreak());
    try std.testing.expect(editor.insertLineBreak());
    try std.testing.expectEqualStrings("a\n\n", editor.text());
    try std.testing.expect(editor.backspace());
    try std.testing.expectEqualStrings("a\n", editor.text());
    try std.testing.expect(editor.backspace());
    try std.testing.expectEqualStrings("a", editor.text());
}

test "repeated insertion applies the complete batch with one buffer shift" {
    var editor: Editor = .{};
    try editor.setText("ac");
    editor.cursor = 1;
    try std.testing.expect(editor.insertRepeated("b", 4));
    try std.testing.expectEqualStrings("abbbbc", editor.text());
    try std.testing.expectEqual(@as(usize, 5), editor.cursor);
}

test "UTF-8 fallback navigation and deletion stay on codepoint boundaries" {
    var editor: Editor = .{};
    try editor.setText("aé");
    try std.testing.expect(editor.moveLeft());
    try std.testing.expectEqual(@as(usize, 1), editor.cursor);
    try std.testing.expect(editor.deleteForward());
    try std.testing.expectEqualStrings("a", editor.text());
}

test "vertical movement follows visual rows and preserves the preferred x" {
    var editor: Editor = .{};
    try editor.setText("abcd");
    editor.beginCaretLayout();
    editor.addCaretStop(0, 10, 20, 0);
    editor.addCaretStop(1, 20, 20, 0);
    editor.addCaretStop(2, 10, 40, 1);
    editor.addCaretStop(3, 21, 40, 1);
    editor.addCaretStop(4, 10, 60, 2);
    editor.finishCaretLayout();
    editor.cursor = 1;

    try std.testing.expect(editor.moveVertical(.down));
    try std.testing.expectEqual(@as(usize, 3), editor.cursor);
    try std.testing.expect(editor.moveVertical(.down));
    try std.testing.expectEqual(@as(usize, 4), editor.cursor);
}
