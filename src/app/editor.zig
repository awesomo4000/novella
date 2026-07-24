// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const Document = @import("document.zig").Document;

pub const CaretStop = struct {
    offset: usize,
    x: f64,
    y: f64,
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

    pub fn insert(self: *Editor, source: []const u8) !bool {
        self.preferred_x_active = false;
        return self.document.insertUtf8(source);
    }

    pub fn insertParagraph(self: *Editor) !bool {
        return self.insert("\n");
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

    pub fn deleteBackward(self: *Editor, caret_map: *const CaretMap) !bool {
        self.preferred_x_active = false;
        const cursor = self.document.cursor;
        if (cursor == 0) return false;
        const start = caret_map.previousBoundary(
            self.document.revision,
            cursor,
        ) orelse self.document.previousCodepoint(cursor);
        return self.document.deleteRange(start, cursor);
    }

    pub fn deleteForward(self: *Editor, caret_map: *const CaretMap) !bool {
        self.preferred_x_active = false;
        const cursor = self.document.cursor;
        if (cursor == self.document.len()) return false;
        const end = caret_map.nextBoundary(
            self.document.revision,
            cursor,
            self.document.len(),
        ) orelse self.document.nextCodepoint(cursor);
        return self.document.deleteRange(cursor, end);
    }

    pub fn moveVertically(self: *Editor, caret_map: *const CaretMap, up: bool) !bool {
        if (caret_map.revision != self.document.revision) return false;
        const current = caret_map.stopForOffset(self.document.cursor) orelse return false;
        if (!self.preferred_x_active) {
            self.preferred_x = current.x;
            self.preferred_x_active = true;
        }

        var target_y: ?f64 = null;
        for (caret_map.stops.items) |stop| {
            if (up) {
                if (stop.y >= current.y - 1.0) continue;
                if (target_y == null or stop.y > target_y.?) target_y = stop.y;
            } else {
                if (stop.y <= current.y + 1.0) continue;
                if (target_y == null or stop.y < target_y.?) target_y = stop.y;
            }
        }
        const row_y = target_y orelse return false;

        var best: ?CaretStop = null;
        var best_distance = std.math.inf(f64);
        for (caret_map.stops.items) |stop| {
            if (@abs(stop.y - row_y) > 0.5) continue;
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

test "editor uses shaped caret boundaries for horizontal movement and deletion" {
    var editor = try Editor.init(std.testing.allocator, "office");
    defer editor.deinit();
    var map = CaretMap.init(std.testing.allocator);
    defer map.deinit();
    try map.add(.{ .offset = 0, .x = 0, .y = 0 });
    try map.add(.{ .offset = 1, .x = 1, .y = 0 });
    try map.add(.{ .offset = 4, .x = 2, .y = 0 });
    try map.add(.{ .offset = 5, .x = 3, .y = 0 });
    try map.add(.{ .offset = 6, .x = 4, .y = 0 });
    map.finish(editor.document.revision);

    try std.testing.expect(try editor.moveLeft(&map));
    try std.testing.expectEqual(@as(usize, 5), editor.document.cursor);
    try std.testing.expect(try editor.moveLeft(&map));
    try std.testing.expectEqual(@as(usize, 4), editor.document.cursor);
    try std.testing.expect(try editor.deleteBackward(&map));
    try std.testing.expectEqualStrings("oce", editor.text());
}

test "editor vertical movement preserves the desired column" {
    var editor = try Editor.init(std.testing.allocator, "abcdef");
    defer editor.deinit();
    var map = CaretMap.init(std.testing.allocator);
    defer map.deinit();
    try map.add(.{ .offset = 0, .x = 0, .y = 0 });
    try map.add(.{ .offset = 1, .x = 10, .y = 0 });
    try map.add(.{ .offset = 2, .x = 20, .y = 0 });
    try map.add(.{ .offset = 3, .x = 0, .y = 20 });
    try map.add(.{ .offset = 4, .x = 9, .y = 20 });
    try map.add(.{ .offset = 5, .x = 0, .y = 40 });
    try map.add(.{ .offset = 6, .x = 8, .y = 40 });
    map.finish(editor.document.revision);

    try editor.document.setCursor(2);
    try std.testing.expect(try editor.moveVertically(&map, false));
    try std.testing.expectEqual(@as(usize, 4), editor.document.cursor);
    try std.testing.expect(try editor.moveVertically(&map, false));
    try std.testing.expectEqual(@as(usize, 6), editor.document.cursor);
    try std.testing.expect(try editor.moveVertically(&map, true));
    try std.testing.expectEqual(@as(usize, 4), editor.document.cursor);
}

test "stale layout falls back to UTF-8 codepoint boundaries" {
    var editor = try Editor.init(std.testing.allocator, "aé");
    defer editor.deinit();
    var map = CaretMap.init(std.testing.allocator);
    defer map.deinit();

    try std.testing.expect(try editor.moveLeft(&map));
    try std.testing.expectEqual(@as(usize, 1), editor.document.cursor);
    try std.testing.expect(try editor.deleteForward(&map));
    try std.testing.expectEqualStrings("a", editor.text());
}
