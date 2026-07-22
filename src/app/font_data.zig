// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const junicode_font = @import("junicode_font");

pub const junicode_uncompressed_size = 2_906_772;

pub fn loadJunicode(allocator: std.mem.Allocator) ![]u8 {
    var input: std.Io.Reader = .fixed(junicode_font.compressed);
    var decompress = std.compress.xz.Decompress.init(&input, allocator, &.{}) catch
        return error.FontDecompressionFailed;
    defer decompress.deinit();

    const font_bytes = try allocator.alloc(u8, junicode_uncompressed_size);
    errdefer allocator.free(font_bytes);
    decompress.reader.readSliceAll(font_bytes) catch
        return error.FontDecompressionFailed;

    // Reading through end-of-stream forces XZ footer and checksum validation.
    var trailing: [1]u8 = undefined;
    const trailing_len = decompress.reader.readSliceShort(&trailing) catch
        return error.FontDecompressionFailed;
    if (trailing_len != 0) return error.UnexpectedFontData;

    // Junicode is a TrueType-flavored SFNT. Reject a valid XZ stream that is
    // nevertheless not the embedded font expected by every platform backend.
    if (!std.mem.eql(u8, font_bytes[0..4], &.{ 0x00, 0x01, 0x00, 0x00 }))
        return error.UnexpectedFontData;
    return font_bytes;
}
