// SPDX-License-Identifier: MPL-2.0

const std = @import("std");

pub const Decoder = struct {
    pending_high_surrogate: ?u16 = null,

    pub fn reset(self: *Decoder) void {
        self.pending_high_surrogate = null;
    }

    pub fn push(self: *Decoder, code_unit: u16) ?u21 {
        if (code_unit >= 0xd800 and code_unit <= 0xdbff) {
            self.pending_high_surrogate = code_unit;
            return null;
        }
        if (code_unit >= 0xdc00 and code_unit <= 0xdfff) {
            const high = self.pending_high_surrogate orelse return null;
            self.pending_high_surrogate = null;
            return @intCast(
                0x10000 +
                    ((@as(u32, high) - 0xd800) << 10) +
                    (@as(u32, code_unit) - 0xdc00),
            );
        }

        self.pending_high_surrogate = null;
        return @intCast(code_unit);
    }
};

pub fn messageRepeatCount(message_data: usize) usize {
    return @max(@as(usize, 1), message_data & 0xffff);
}

test "decoder combines UTF-16 surrogate pairs" {
    var decoder: Decoder = .{};
    try std.testing.expectEqual(@as(?u21, null), decoder.push(0xd83d));
    try std.testing.expectEqual(@as(?u21, 0x1f642), decoder.push(0xde42));
}

test "decoder emits BMP codepoints and rejects unmatched low surrogates" {
    var decoder: Decoder = .{};
    try std.testing.expectEqual(@as(?u21, 'A'), decoder.push('A'));
    try std.testing.expectEqual(@as(?u21, null), decoder.push(0xdc00));
    try std.testing.expectEqual(@as(?u21, 'B'), decoder.push('B'));
}

test "message repeat count uses the low word and treats zero as one" {
    try std.testing.expectEqual(@as(usize, 1), messageRepeatCount(0));
    try std.testing.expectEqual(@as(usize, 7), messageRepeatCount(0x4000_0007));
}
