// SPDX-License-Identifier: MPL-2.0

const std = @import("std");

pub const body_font_size: f64 = 18.5;
pub const line_height: f64 = 27.2;
pub const paragraph_gap: f64 = 10.5;

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn red(self: Color) f64 {
        return @as(f64, @floatFromInt(self.r)) / 255.0;
    }

    pub fn green(self: Color) f64 {
        return @as(f64, @floatFromInt(self.g)) / 255.0;
    }

    pub fn blue(self: Color) f64 {
        return @as(f64, @floatFromInt(self.b)) / 255.0;
    }
};

pub const desktop = Color{ .r = 223, .g = 225, .b = 223 };
pub const paper = Color{ .r = 255, .g = 255, .b = 254 };
pub const paper_border = Color{ .r = 215, .g = 216, .b = 212 };
pub const shadow_outer = Color{ .r = 199, .g = 202, .b = 199 };
pub const shadow_inner = Color{ .r = 210, .g = 212, .b = 209 };
pub const ink = Color{ .r = 24, .g = 24, .b = 23 };
pub const caret = Color{ .r = 143, .g = 43, .b = 34 };

pub const Geometry = struct {
    paper_left: f64,
    paper_top: f64,
    paper_width: f64,
    paper_height: f64,
    content_left: f64,
    measure_width: f64,
    first_baseline_top: f64,
};

/// Shared sheet geometry in top-left logical coordinates. Platform canvases
/// convert this once if their native coordinate system points upward.
pub fn geometry(width: f64, height: f64) Geometry {
    const paper_width = @min(646.0, @max(320.0, width - 86.0));
    const paper_height = @max(300.0, height - 34.0);
    const paper_left = (width - paper_width) / 2.0;
    const paper_top = 14.0;
    const inset = @max(48.0, @min(74.0, paper_width * 0.115));
    return .{
        .paper_left = paper_left,
        .paper_top = paper_top,
        .paper_width = paper_width,
        .paper_height = paper_height,
        .content_left = paper_left + inset,
        .measure_width = paper_width - 2.0 * inset,
        .first_baseline_top = paper_top + 60.0,
    };
}

pub fn scaledGeometry(width: f64, height: f64, scale: f64) Geometry {
    std.debug.assert(scale > 0 and std.math.isFinite(scale));
    var result = geometry(width / scale, height / scale);
    inline for (std.meta.fields(Geometry)) |field|
        @field(result, field.name) *= scale;
    return result;
}

test "shared sheet geometry matches the 900 by 760 baseline" {
    const result = geometry(900, 760);
    try std.testing.expectApproxEqAbs(@as(f64, 127), result.paper_left, 0.000_001);
    try std.testing.expectApproxEqAbs(@as(f64, 14), result.paper_top, 0.000_001);
    try std.testing.expectApproxEqAbs(@as(f64, 646), result.paper_width, 0.000_001);
    try std.testing.expectApproxEqAbs(@as(f64, 726), result.paper_height, 0.000_001);
    try std.testing.expectApproxEqAbs(@as(f64, 201), result.content_left, 0.000_001);
    try std.testing.expectApproxEqAbs(@as(f64, 498), result.measure_width, 0.000_001);
    try std.testing.expectApproxEqAbs(@as(f64, 74), result.first_baseline_top, 0.000_001);
}

test "scaled geometry preserves logical proportions in physical pixels" {
    const result = scaledGeometry(1125, 950, 1.25);
    try std.testing.expectApproxEqAbs(@as(f64, 158.75), result.paper_left, 0.000_001);
    try std.testing.expectApproxEqAbs(@as(f64, 807.5), result.paper_width, 0.000_001);
    try std.testing.expectApproxEqAbs(@as(f64, 251.25), result.content_left, 0.000_001);
    try std.testing.expectApproxEqAbs(@as(f64, 622.5), result.measure_width, 0.000_001);
}
