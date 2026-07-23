// SPDX-License-Identifier: MPL-2.0

pub const FrameRequest = struct {
    width: u16,
    height: u16,
    dirty: bool = false,

    pub fn init(width: u16, height: u16) FrameRequest {
        return .{ .width = width, .height = height };
    }

    pub fn expose(self: *FrameRequest) void {
        self.dirty = true;
    }

    pub fn configure(self: *FrameRequest, width: u16, height: u16) void {
        self.width = width;
        self.height = height;
        self.dirty = true;
    }
};

test "queued configurations retain only the latest size" {
    const std = @import("std");

    var request = FrameRequest.init(900, 760);
    request.configure(910, 770);
    request.configure(930, 790);
    request.configure(920, 780);

    try std.testing.expect(request.dirty);
    try std.testing.expectEqual(@as(u16, 920), request.width);
    try std.testing.expectEqual(@as(u16, 780), request.height);
}
