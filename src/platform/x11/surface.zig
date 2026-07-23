// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const sheet = @import("sheet");

pub const PixelFormat = struct {
    bits_per_pixel: u8,
    scanline_pad: u8,
    lsb_first: bool,
    red_mask: u32,
    green_mask: u32,
    blue_mask: u32,

    pub fn validate(self: PixelFormat) !void {
        if (self.bits_per_pixel != 24 and self.bits_per_pixel != 32)
            return error.UnsupportedX11BitsPerPixel;
        if (self.scanline_pad != 8 and self.scanline_pad != 16 and self.scanline_pad != 32)
            return error.UnsupportedX11ScanlinePad;
        if (self.red_mask == 0 or self.green_mask == 0 or self.blue_mask == 0)
            return error.UnsupportedX11VisualMasks;
        if ((self.red_mask & self.green_mask) != 0 or
            (self.red_mask & self.blue_mask) != 0 or
            (self.green_mask & self.blue_mask) != 0)
            return error.UnsupportedX11VisualMasks;
    }
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const Surface = struct {
    allocator: std.mem.Allocator,
    format: PixelFormat,
    pixels: []u8 = &.{},
    width: u16 = 0,
    height: u16 = 0,
    stride: usize = 0,

    pub fn init(allocator: std.mem.Allocator, format: PixelFormat) !Surface {
        try format.validate();
        return .{ .allocator = allocator, .format = format };
    }

    pub fn deinit(self: *Surface) void {
        if (self.pixels.len > 0) self.allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn resize(self: *Surface, width: u16, height: u16) !void {
        if (self.width == width and self.height == height and self.pixels.len > 0) return;
        const row_bits = try std.math.mul(usize, width, self.format.bits_per_pixel);
        const padded_bits = std.mem.alignForward(usize, row_bits, self.format.scanline_pad);
        const stride = padded_bits / 8;
        const byte_count = try std.math.mul(usize, stride, height);
        const replacement = try self.allocator.alloc(u8, byte_count);
        errdefer self.allocator.free(replacement);
        @memset(replacement, 0);
        if (self.pixels.len > 0) self.allocator.free(self.pixels);
        self.pixels = replacement;
        self.width = width;
        self.height = height;
        self.stride = stride;
    }

    pub fn fill(self: *Surface, color: sheet.Color) void {
        self.fillRect(.{ .x = 0, .y = 0, .width = self.width, .height = self.height }, color);
    }

    pub fn nativePixel(self: *const Surface, color: sheet.Color) u32 {
        return self.pack(color);
    }

    pub fn fillRect(self: *Surface, rect: Rect, color: sheet.Color) void {
        const left: i32 = @max(0, rect.x);
        const top: i32 = @max(0, rect.y);
        const right: i32 = @min(@as(i32, self.width), rect.x + @max(0, rect.width));
        const bottom: i32 = @min(@as(i32, self.height), rect.y + @max(0, rect.height));
        if (left >= right or top >= bottom) return;

        const pixel = self.pack(color);
        const bytes_per_pixel = self.format.bits_per_pixel / 8;
        var y: usize = @intCast(top);
        while (y < @as(usize, @intCast(bottom))) : (y += 1) {
            var offset = y * self.stride + @as(usize, @intCast(left)) * bytes_per_pixel;
            var x: i32 = left;
            while (x < right) : (x += 1) {
                self.writePixel(offset, pixel);
                offset += bytes_per_pixel;
            }
        }
    }

    pub fn paintSheet(self: *Surface) void {
        self.fill(sheet.desktop);
        const geometry = sheet.geometry(self.width, self.height);
        const paper_rect = rectFromFloats(
            geometry.paper_left,
            geometry.paper_top,
            geometry.paper_width,
            geometry.paper_height,
        );

        self.fillRect(.{
            .x = paper_rect.x + 8,
            .y = paper_rect.y + 9,
            .width = paper_rect.width,
            .height = paper_rect.height,
        }, sheet.shadow_outer);
        self.fillRect(.{
            .x = paper_rect.x + 3,
            .y = paper_rect.y + 4,
            .width = paper_rect.width,
            .height = paper_rect.height,
        }, sheet.shadow_inner);
        self.fillRect(paper_rect, sheet.paper_border);
        self.fillRect(.{
            .x = paper_rect.x + 1,
            .y = paper_rect.y + 1,
            .width = paper_rect.width - 2,
            .height = paper_rect.height - 2,
        }, sheet.paper);
    }

    pub fn blendPixel(self: *Surface, x: i32, y: i32, color: sheet.Color, coverage: u8) void {
        if (coverage == 0 or x < 0 or y < 0 or x >= self.width or y >= self.height) return;
        const bytes_per_pixel: usize = self.format.bits_per_pixel / 8;
        const offset = @as(usize, @intCast(y)) * self.stride +
            @as(usize, @intCast(x)) * bytes_per_pixel;
        if (coverage == 255) {
            self.writePixel(offset, self.pack(color));
            return;
        }

        const background = self.unpack(self.readPixel(offset));
        const inverse: u16 = 255 - coverage;
        self.writePixel(offset, self.pack(.{
            .r = @intCast((@as(u16, color.r) * coverage + @as(u16, background.r) * inverse + 127) / 255),
            .g = @intCast((@as(u16, color.g) * coverage + @as(u16, background.g) * inverse + 127) / 255),
            .b = @intCast((@as(u16, color.b) * coverage + @as(u16, background.b) * inverse + 127) / 255),
        }));
    }

    fn pack(self: *const Surface, color: sheet.Color) u32 {
        return channelToMask(color.r, self.format.red_mask) |
            channelToMask(color.g, self.format.green_mask) |
            channelToMask(color.b, self.format.blue_mask);
    }

    fn unpack(self: *const Surface, pixel: u32) sheet.Color {
        return .{
            .r = maskToChannel(pixel, self.format.red_mask),
            .g = maskToChannel(pixel, self.format.green_mask),
            .b = maskToChannel(pixel, self.format.blue_mask),
        };
    }

    fn readPixel(self: *const Surface, offset: usize) u32 {
        const count: usize = self.format.bits_per_pixel / 8;
        var pixel: u32 = 0;
        for (0..count) |index| {
            const shift_index = if (self.format.lsb_first) index else count - 1 - index;
            pixel |= @as(u32, self.pixels[offset + index]) << @intCast(shift_index * 8);
        }
        return pixel;
    }

    fn writePixel(self: *Surface, offset: usize, pixel: u32) void {
        const count: usize = self.format.bits_per_pixel / 8;
        for (0..count) |index| {
            const shift_index = if (self.format.lsb_first) index else count - 1 - index;
            self.pixels[offset + index] = @truncate(pixel >> @intCast(shift_index * 8));
        }
    }
};

fn rectFromFloats(x: f64, y: f64, width: f64, height: f64) Rect {
    return .{
        .x = @intFromFloat(@round(x)),
        .y = @intFromFloat(@round(y)),
        .width = @intFromFloat(@round(width)),
        .height = @intFromFloat(@round(height)),
    };
}

fn channelToMask(channel: u8, mask: u32) u32 {
    const shift: u5 = @intCast(@ctz(mask));
    const shifted_mask = mask >> shift;
    const maximum: u64 = shifted_mask;
    const scaled: u32 = @intCast((@as(u64, channel) * maximum + 127) / 255);
    return (scaled << shift) & mask;
}

fn maskToChannel(pixel: u32, mask: u32) u8 {
    const shift: u5 = @intCast(@ctz(mask));
    const maximum: u64 = mask >> shift;
    const value: u64 = (pixel & mask) >> shift;
    return @intCast((value * 255 + maximum / 2) / maximum);
}

test "native pixel packing follows masks and byte order" {
    var little = try Surface.init(std.testing.allocator, .{
        .bits_per_pixel = 32,
        .scanline_pad = 32,
        .lsb_first = true,
        .red_mask = 0x00ff0000,
        .green_mask = 0x0000ff00,
        .blue_mask = 0x000000ff,
    });
    defer little.deinit();
    try little.resize(1, 1);
    const color = sheet.Color{ .r = 0x12, .g = 0x34, .b = 0x56 };
    try std.testing.expectEqual(@as(u32, 0x00123456), little.nativePixel(color));
    little.fill(color);
    try std.testing.expectEqualSlices(u8, &.{ 0x56, 0x34, 0x12, 0x00 }, little.pixels);
}
