// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const Document = @import("document.zig").Document;

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

pub const CaretMap = struct {
    allocator: std.mem.Allocator,
    stops: std.ArrayList(CaretStop) = .empty,
    revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) CaretMap {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CaretMap) void {
        self.stops.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn begin(self: *CaretMap) void {
        self.stops.clearRetainingCapacity();
        self.revision = 0;
    }

    pub fn finish(self: *CaretMap, revision: u64) void {
        self.revision = revision;
    }

    pub fn add(self: *CaretMap, stop: CaretStop) !void {
        if (self.stops.items.len > 0) {
            const previous = &self.stops.items[self.stops.items.len - 1];
            if (previous.offset == stop.offset) {
                previous.* = stop;
                return;
            }
        }
        try self.stops.append(self.allocator, stop);
    }

    pub fn stopForOffset(self: *const CaretMap, offset: usize) ?CaretStop {
        var nearest: ?CaretStop = null;
        for (self.stops.items) |stop| {
            if (stop.offset == offset) return stop;
            if (stop.offset < offset and (nearest == null or stop.offset > nearest.?.offset))
                nearest = stop;
        }
        return nearest;
    }

    fn previousBoundary(self: *const CaretMap, revision: u64, position: usize) ?usize {
        if (self.revision != revision) return null;
        var previous: ?usize = null;
        var found = false;
        for (self.stops.items) |stop| {
            if (stop.offset == position) found = true;
            if (stop.offset < position and (previous == null or stop.offset > previous.?))
                previous = stop.offset;
        }
        return if (found) previous orelse 0 else null;
    }

    fn nextBoundary(self: *const CaretMap, revision: u64, position: usize, end: usize) ?usize {
        if (self.revision != revision) return null;
        var next: ?usize = null;
        var found = false;
        for (self.stops.items) |stop| {
            if (stop.offset == position) found = true;
            if (stop.offset > position and (next == null or stop.offset < next.?))
                next = stop.offset;
        }
        return if (found) next orelse end else null;
    }
};

pub const Editor = struct {
    document: Document,
    preferred_x: f64 = 0,
    preferred_x_active: bool = false,

    pub fn init(allocator: std.mem.Allocator, initial_text: []const u8) !Editor {
        return .{ .document = try Document.init(allocator, initial_text) };
    }

    pub fn deinit(self: *Editor) void {
        self.document.deinit();
        self.* = undefined;
    }

    pub fn text(self: *Editor) []const u8 {
        return self.document.text();
    }

    pub fn cursor(self: *const Editor) usize {
        return self.document.cursor;
    }

    pub fn revision(self: *const Editor) u64 {
        return self.document.revision;
    }

    pub fn insert(self: *Editor, source: []const u8) !bool {
        return self.insertRepeated(source, 1);
    }

    pub fn insertRepeated(
        self: *Editor,
        source: []const u8,
        requested_count: usize,
    ) !bool {
        self.preferred_x_active = false;
        return self.document.insertRepeatedUtf8(source, requested_count);
    }

    pub fn insertLineBreak(self: *Editor) !bool {
        return self.insert("\n");
    }

    pub fn backspace(self: *Editor, caret_map: *const CaretMap) !bool {
        self.preferred_x_active = false;
        const position = self.document.cursor;
        if (position == 0) return false;
        const start = caret_map.previousBoundary(
            self.document.revision,
            position,
        ) orelse self.document.previousCodepoint(position);
        return self.document.deleteRange(start, position);
    }

    pub fn deleteForward(self: *Editor, caret_map: *const CaretMap) !bool {
        self.preferred_x_active = false;
        const position = self.document.cursor;
        if (position == self.document.len()) return false;
        const end = caret_map.nextBoundary(
            self.document.revision,
            position,
            self.document.len(),
        ) orelse self.document.nextCodepoint(position);
        return self.document.deleteRange(position, end);
    }

    pub fn moveLeft(self: *Editor, caret_map: *const CaretMap) !bool {
        self.preferred_x_active = false;
        const old = self.document.cursor;
        const target = caret_map.previousBoundary(
            self.document.revision,
            old,
        ) orelse self.document.previousCodepoint(old);
        try self.document.setCursor(target);
        return target != old;
    }

    pub fn moveRight(self: *Editor, caret_map: *const CaretMap) !bool {
        self.preferred_x_active = false;
        const old = self.document.cursor;
        const target = caret_map.nextBoundary(
            self.document.revision,
            old,
            self.document.len(),
        ) orelse self.document.nextCodepoint(old);
        try self.document.setCursor(target);
        return target != old;
    }

    pub fn moveVertical(
        self: *Editor,
        caret_map: *const CaretMap,
        direction: Direction,
    ) !bool {
        if (caret_map.revision != self.document.revision) return false;
        const current = caret_map.stopForOffset(self.document.cursor) orelse return false;
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
        for (caret_map.stops.items) |stop| {
            if (stop.row != target_row) continue;
            const distance = @abs(stop.x - self.preferred_x);
            if (distance < best_distance) {
                best = stop;
                best_distance = distance;
            }
        }
        const target = best orelse return false;
        const moved = target.offset != self.document.cursor;
        try self.document.setCursor(target.offset);
        return moved;
    }
};

test "line breaks insert and delete one visual boundary at a time" {
    var editor = try Editor.init(std.testing.allocator, "a");
    defer editor.deinit();
    var map = CaretMap.init(std.testing.allocator);
    defer map.deinit();

    try std.testing.expect(try editor.insertLineBreak());
    try std.testing.expect(try editor.insertLineBreak());
    try std.testing.expectEqualStrings("a\n\n", editor.text());
    try std.testing.expect(try editor.backspace(&map));
    try std.testing.expectEqualStrings("a\n", editor.text());
    try std.testing.expect(try editor.backspace(&map));
    try std.testing.expectEqualStrings("a", editor.text());
}

test "editor uses shaped caret boundaries for horizontal movement and deletion" {
    var editor = try Editor.init(std.testing.allocator, "office");
    defer editor.deinit();
    var map = CaretMap.init(std.testing.allocator);
    defer map.deinit();
    try map.add(.{ .offset = 0, .x = 0, .baseline = 0, .row = 0 });
    try map.add(.{ .offset = 1, .x = 1, .baseline = 0, .row = 0 });
    try map.add(.{ .offset = 4, .x = 2, .baseline = 0, .row = 0 });
    try map.add(.{ .offset = 5, .x = 3, .baseline = 0, .row = 0 });
    try map.add(.{ .offset = 6, .x = 4, .baseline = 0, .row = 0 });
    map.finish(editor.revision());

    try std.testing.expect(try editor.moveLeft(&map));
    try std.testing.expectEqual(@as(usize, 5), editor.cursor());
    try std.testing.expect(try editor.moveLeft(&map));
    try std.testing.expectEqual(@as(usize, 4), editor.cursor());
    try std.testing.expect(try editor.backspace(&map));
    try std.testing.expectEqualStrings("oce", editor.text());
}

test "repeated insertion applies one dynamic document edit" {
    var editor = try Editor.init(std.testing.allocator, "ac");
    defer editor.deinit();
    try editor.document.setCursor(1);

    try std.testing.expect(try editor.insertRepeated("b", 4));
    try std.testing.expectEqualStrings("abbbbc", editor.text());
    try std.testing.expectEqual(@as(usize, 5), editor.cursor());
}

test "UTF-8 fallback navigation and deletion stay on codepoint boundaries" {
    var editor = try Editor.init(std.testing.allocator, "aé");
    defer editor.deinit();
    var map = CaretMap.init(std.testing.allocator);
    defer map.deinit();

    try std.testing.expect(try editor.moveLeft(&map));
    try std.testing.expectEqual(@as(usize, 1), editor.cursor());
    try std.testing.expect(try editor.deleteForward(&map));
    try std.testing.expectEqualStrings("a", editor.text());
}

test "vertical movement follows rows and preserves the preferred x" {
    var editor = try Editor.init(std.testing.allocator, "abcdef");
    defer editor.deinit();
    var map = CaretMap.init(std.testing.allocator);
    defer map.deinit();
    try map.add(.{ .offset = 0, .x = 0, .baseline = 0, .row = 0 });
    try map.add(.{ .offset = 1, .x = 10, .baseline = 0, .row = 0 });
    try map.add(.{ .offset = 2, .x = 20, .baseline = 0, .row = 0 });
    try map.add(.{ .offset = 3, .x = 0, .baseline = 20, .row = 1 });
    try map.add(.{ .offset = 4, .x = 9, .baseline = 20, .row = 1 });
    try map.add(.{ .offset = 5, .x = 0, .baseline = 40, .row = 2 });
    try map.add(.{ .offset = 6, .x = 8, .baseline = 40, .row = 2 });
    map.finish(editor.revision());

    try editor.document.setCursor(2);
    try std.testing.expect(try editor.moveVertical(&map, .down));
    try std.testing.expectEqual(@as(usize, 4), editor.cursor());
    try std.testing.expect(try editor.moveVertical(&map, .down));
    try std.testing.expectEqual(@as(usize, 6), editor.cursor());
    try std.testing.expect(try editor.moveVertical(&map, .up));
    try std.testing.expectEqual(@as(usize, 4), editor.cursor());
}
