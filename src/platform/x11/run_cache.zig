// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const shaping = @import("text_engine");

pub const RunCache = struct {
    allocator: std.mem.Allocator,
    engine: *const shaping.Engine,
    runs: std.StringHashMapUnmanaged(shaping.Run) = .empty,

    pub fn init(allocator: std.mem.Allocator, engine: *const shaping.Engine) RunCache {
        return .{ .allocator = allocator, .engine = engine };
    }

    pub fn deinit(self: *RunCache) void {
        var iterator = self.runs.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.runs.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn shape(self: *RunCache, source: []const u8) !shaping.Run {
        if (self.runs.get(source)) |run| return run;

        const key = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(key);
        const run = try self.engine.shape(self.allocator, source);
        errdefer {
            var owned = run;
            owned.deinit(self.allocator);
        }
        try self.runs.put(self.allocator, key, run);
        return run;
    }
};
