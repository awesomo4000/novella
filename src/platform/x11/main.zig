// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const novella = @import("novella");
const sheet = @import("sheet");
const shaping = @import("text_engine");
const font_data = @import("font_data");
const rasterizer = @import("freetype.zig");
const Surface = @import("surface.zig").Surface;
const PixelFormat = @import("surface.zig").PixelFormat;

const xcb = @cImport({
    @cInclude("stdlib.h");
    @cInclude("xcb.h");
});

const initial_width: u16 = 900;
const initial_height: u16 = 760;
const max_text_bytes = 64 * 1024;

const CachedRun = struct {
    source: []const u8,
    run: shaping.Run,
};

const FrameShaper = struct {
    allocator: std.mem.Allocator,
    engine: *const shaping.Engine,
    runs: std.ArrayList(CachedRun) = .empty,

    fn deinit(self: *FrameShaper) void {
        for (self.runs.items) |*entry| entry.run.deinit(self.allocator);
        self.runs.deinit(self.allocator);
    }

    fn shape(self: *FrameShaper, source: []const u8) !shaping.Run {
        for (self.runs.items) |entry| {
            if (entry.source.ptr == source.ptr and entry.source.len == source.len)
                return entry.run;
        }
        const run = try self.engine.shape(self.allocator, source);
        errdefer {
            var owned = run;
            owned.deinit(self.allocator);
        }
        try self.runs.append(self.allocator, .{ .source = source, .run = run });
        return run;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const initial_text = try loadInitialText(init);
    const font_bytes = try font_data.loadJunicode(allocator);
    defer allocator.free(font_bytes);
    var text_engine = try shaping.Engine.init(font_bytes, sheet.body_font_size);
    defer text_engine.deinit();
    var glyph_engine = try rasterizer.Engine.init(font_bytes, sheet.body_font_size);
    defer glyph_engine.deinit();

    var screen_number: c_int = 0;
    const connection = xcb.xcb_connect(null, &screen_number) orelse
        return error.X11ConnectionFailed;
    defer xcb.xcb_disconnect(connection);
    if (xcb.xcb_connection_has_error(connection) != 0)
        return error.X11ConnectionFailed;

    const setup = xcb.xcb_get_setup(connection) orelse
        return error.X11SetupUnavailable;
    const screen = findScreen(setup, screen_number) orelse
        return error.X11ScreenUnavailable;
    const visual = findRootVisual(screen) orelse
        return error.X11RootVisualUnavailable;
    if (visual.*._class != xcb.XCB_VISUAL_CLASS_TRUE_COLOR)
        return error.UnsupportedX11VisualClass;
    const pixmap_format = findPixmapFormat(setup, screen.*.root_depth) orelse
        return error.X11PixmapFormatUnavailable;

    var surface = try Surface.init(allocator, PixelFormat{
        .bits_per_pixel = pixmap_format.*.bits_per_pixel,
        .scanline_pad = pixmap_format.*.scanline_pad,
        .lsb_first = setup.*.image_byte_order == xcb.XCB_IMAGE_ORDER_LSB_FIRST,
        .red_mask = visual.*.red_mask,
        .green_mask = visual.*.green_mask,
        .blue_mask = visual.*.blue_mask,
    });
    defer surface.deinit();
    try surface.resize(initial_width, initial_height);

    const window = xcb.xcb_generate_id(connection);
    const event_mask: u32 = xcb.XCB_EVENT_MASK_EXPOSURE |
        xcb.XCB_EVENT_MASK_KEY_PRESS |
        xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY;
    const values = [_]u32{ screen.*.black_pixel, event_mask };
    _ = xcb.xcb_create_window(
        connection,
        screen.*.root_depth,
        window,
        screen.*.root,
        0,
        0,
        initial_width,
        initial_height,
        0,
        xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT,
        screen.*.root_visual,
        xcb.XCB_CW_BACK_PIXEL | xcb.XCB_CW_EVENT_MASK,
        &values,
    );
    defer _ = xcb.xcb_destroy_window(connection, window);

    const gc = xcb.xcb_generate_id(connection);
    _ = xcb.xcb_create_gc(connection, gc, window, 0, null);
    defer _ = xcb.xcb_free_gc(connection, gc);

    const wm_protocols = try internAtom(connection, "WM_PROTOCOLS");
    const wm_delete_window = try internAtom(connection, "WM_DELETE_WINDOW");
    const utf8_string = try internAtom(connection, "UTF8_STRING");
    const net_wm_name = try internAtom(connection, "_NET_WM_NAME");
    const delete_atoms = [_]xcb.xcb_atom_t{wm_delete_window};
    _ = xcb.xcb_change_property(
        connection,
        xcb.XCB_PROP_MODE_REPLACE,
        window,
        wm_protocols,
        xcb.XCB_ATOM_ATOM,
        32,
        delete_atoms.len,
        &delete_atoms,
    );

    const title = "Novella - a justified writing sheet";
    _ = xcb.xcb_change_property(
        connection,
        xcb.XCB_PROP_MODE_REPLACE,
        window,
        xcb.XCB_ATOM_WM_NAME,
        xcb.XCB_ATOM_STRING,
        8,
        title.len,
        title.ptr,
    );
    _ = xcb.xcb_change_property(
        connection,
        xcb.XCB_PROP_MODE_REPLACE,
        window,
        net_wm_name,
        utf8_string,
        8,
        title.len,
        title.ptr,
    );
    const wm_class = "novella\x00Novella\x00";
    _ = xcb.xcb_change_property(
        connection,
        xcb.XCB_PROP_MODE_REPLACE,
        window,
        xcb.XCB_ATOM_WM_CLASS,
        xcb.XCB_ATOM_STRING,
        8,
        wm_class.len,
        wm_class.ptr,
    );

    _ = xcb.xcb_map_window(connection, window);
    var dirty = true;
    if (xcb.xcb_flush(connection) <= 0) return error.X11FlushFailed;

    event_loop: while (xcb.xcb_connection_has_error(connection) == 0) {
        if (dirty) {
            try paintDocument(&surface, initial_text, &text_engine, &glyph_engine);
            try present(connection, window, gc, screen.*.root_depth, &surface);
            dirty = false;
        }

        const event = xcb.xcb_wait_for_event(connection) orelse break;
        defer xcb.free(event);
        const event_type = event.*.response_type & 0x7f;
        switch (event_type) {
            xcb.XCB_EXPOSE => dirty = true,
            xcb.XCB_CONFIGURE_NOTIFY => {
                const configured: *const xcb.xcb_configure_notify_event_t = @ptrCast(event);
                if (configured.*.width != surface.width or configured.*.height != surface.height) {
                    try surface.resize(configured.*.width, configured.*.height);
                    dirty = true;
                }
            },
            xcb.XCB_CLIENT_MESSAGE => {
                const message: *const xcb.xcb_client_message_event_t = @ptrCast(event);
                if (message.*.type == wm_protocols and
                    message.*.format == 32 and
                    message.*.data.data32[0] == wm_delete_window)
                    break :event_loop;
            },
            xcb.XCB_DESTROY_NOTIFY => break :event_loop,
            else => {},
        }
    }
    if (xcb.xcb_connection_has_error(connection) != 0)
        return error.X11ConnectionLost;
}

fn loadInitialText(init: std.process.Init) ![]const u8 {
    const allocator = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(allocator);
    if (arguments.len == 1) return "";
    if (std.mem.eql(u8, arguments[1], "-h") or std.mem.eql(u8, arguments[1], "--help")) {
        var output_buffer: [1024]u8 = undefined;
        var output = std.Io.File.stdout().writer(init.io, &output_buffer);
        try output.interface.writeAll(
            \\Usage: novella-x11 [-f FILE | - | --text TEXT]
            \\
            \\  -f FILE      Open UTF-8 text from a file
            \\  -             Read UTF-8 text from stdin
            \\  --text TEXT   Open literal UTF-8 text
            \\
        );
        try output.interface.flush();
        std.process.exit(0);
    }

    var contents: []const u8 = undefined;
    if (std.mem.eql(u8, arguments[1], "-f")) {
        if (arguments.len < 3) return error.MissingFileArgument;
        contents = try std.Io.Dir.cwd().readFileAlloc(
            init.io,
            arguments[2],
            allocator,
            .limited(max_text_bytes + 1),
        );
    } else if (std.mem.eql(u8, arguments[1], "-")) {
        var input_buffer: [4096]u8 = undefined;
        var input = std.Io.File.stdin().reader(init.io, &input_buffer);
        contents = try input.interface.allocRemaining(allocator, .limited(max_text_bytes + 1));
    } else if (std.mem.eql(u8, arguments[1], "--text")) {
        if (arguments.len < 3) return error.MissingTextArgument;
        contents = arguments[2];
    } else {
        return error.UnknownArgument;
    }

    if (contents.len > max_text_bytes) return error.InputTooLong;
    if (!std.unicode.utf8ValidateSlice(contents)) return error.InvalidUtf8;
    if (std.mem.indexOfScalar(u8, contents, '\r') == null) return contents;

    const normalized = try allocator.alloc(u8, contents.len);
    var source: usize = 0;
    var destination: usize = 0;
    while (source < contents.len) : (source += 1) {
        if (contents[source] == '\r') {
            normalized[destination] = '\n';
            destination += 1;
            if (source + 1 < contents.len and contents[source + 1] == '\n') source += 1;
        } else {
            normalized[destination] = contents[source];
            destination += 1;
        }
    }
    return normalized[0..destination];
}

fn paintDocument(
    surface: *Surface,
    text: []const u8,
    text_engine: *const shaping.Engine,
    glyph_engine: *rasterizer.Engine,
) !void {
    surface.paintSheet();
    const geometry = sheet.geometry(surface.width, surface.height);
    var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    var frame_shaper = FrameShaper{ .allocator = allocator, .engine = text_engine };
    defer frame_shaper.deinit();

    var baseline = geometry.first_baseline_top;
    var caret_x = geometry.content_left;
    var caret_y = baseline;
    var paragraph_start: usize = 0;
    while (paragraph_start <= text.len) {
        const rest = text[paragraph_start..];
        const separator = std.mem.indexOfScalar(u8, rest, '\n');
        const paragraph_end = if (separator) |offset| paragraph_start + offset else text.len;
        const paragraph = text[paragraph_start..paragraph_end];
        if (paragraph.len > 0) {
            var layout = try novella.Layout.init(
                allocator,
                paragraph,
                geometry.measure_width,
                .{ .context = &frame_shaper, .measure_fn = measureBodyText },
                .{},
            );
            defer layout.deinit(allocator);

            for (layout.lines) |line| {
                if (baseline > geometry.paper_top + geometry.paper_height - 62.0) break;
                var x = geometry.content_left;
                const words = layout.words[line.word_start..line.word_end];
                for (words, 0..) |word, index| {
                    const run = try frame_shaper.shape(word.text);
                    try glyph_engine.drawRun(surface, run, x, baseline, sheet.ink);
                    x += word.width;
                    if (index + 1 < words.len and words[index + 1].space_before)
                        x += line.space_width;
                }
                caret_x = x;
                caret_y = baseline;
                baseline += sheet.line_height;
            }
            baseline += sheet.paragraph_gap;
        } else if (separator != null) {
            baseline += sheet.line_height + sheet.paragraph_gap;
            caret_x = geometry.content_left;
            caret_y = baseline;
        }
        if (separator == null) break;
        paragraph_start = paragraph_end + 1;
    }

    surface.fillRect(.{
        .x = @intFromFloat(@round(caret_x - 2.0)),
        .y = @intFromFloat(@round(caret_y - 18.0)),
        .width = 2,
        .height = 22,
    }, sheet.caret);
}

fn measureBodyText(context: ?*anyopaque, source: []const u8) f64 {
    const state = context orelse return 0;
    const shaper: *FrameShaper = @ptrCast(@alignCast(state));
    const run = shaper.shape(source) catch return 0;
    return run.advance;
}

fn findScreen(setup: *const xcb.xcb_setup_t, screen_number: c_int) ?*xcb.xcb_screen_t {
    var screens = xcb.xcb_setup_roots_iterator(setup);
    var index: c_int = 0;
    while (index < screen_number and screens.rem > 0) : (index += 1)
        xcb.xcb_screen_next(&screens);
    return screens.data;
}

fn findRootVisual(screen: *const xcb.xcb_screen_t) ?*xcb.xcb_visualtype_t {
    var depths = xcb.xcb_screen_allowed_depths_iterator(screen);
    while (depths.rem > 0) : (xcb.xcb_depth_next(&depths)) {
        var visuals = xcb.xcb_depth_visuals_iterator(depths.data);
        while (visuals.rem > 0) : (xcb.xcb_visualtype_next(&visuals)) {
            if (visuals.data.*.visual_id == screen.*.root_visual) return visuals.data;
        }
    }
    return null;
}

fn findPixmapFormat(setup: *const xcb.xcb_setup_t, depth: u8) ?*xcb.xcb_format_t {
    var formats = xcb.xcb_setup_pixmap_formats_iterator(setup);
    while (formats.rem > 0) : (xcb.xcb_format_next(&formats)) {
        if (formats.data.*.depth == depth) return formats.data;
    }
    return null;
}

fn internAtom(connection: *xcb.xcb_connection_t, name: []const u8) !xcb.xcb_atom_t {
    const cookie = xcb.xcb_intern_atom(connection, 0, @intCast(name.len), name.ptr);
    const reply = xcb.xcb_intern_atom_reply(connection, cookie, null) orelse
        return error.X11AtomUnavailable;
    defer xcb.free(reply);
    return reply.*.atom;
}

fn present(
    connection: *xcb.xcb_connection_t,
    window: xcb.xcb_window_t,
    gc: xcb.xcb_gcontext_t,
    depth: u8,
    surface: *const Surface,
) !void {
    if (surface.pixels.len > std.math.maxInt(u32)) return error.X11FrameTooLarge;
    _ = xcb.xcb_put_image(
        connection,
        xcb.XCB_IMAGE_FORMAT_Z_PIXMAP,
        window,
        gc,
        surface.width,
        surface.height,
        0,
        0,
        0,
        depth,
        @intCast(surface.pixels.len),
        surface.pixels.ptr,
    );
    if (xcb.xcb_flush(connection) <= 0) return error.X11FlushFailed;
}
