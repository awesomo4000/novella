// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const sheet = @import("sheet");
const shaping = @import("text_engine");
const font_data = @import("font_data");
const software = @import("software_renderer");
const editing = @import("editor");
const utf16_input = @import("utf16_input.zig");
const win32 = @import("win32.zig").api;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("NovellaWindow");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("Novella");
const failure_title = std.unicode.utf8ToUtf16LeStringLiteral("Novella could not start");
const failure_message = std.unicode.utf8ToUtf16LeStringLiteral(
    "Windows could not start or render the Novella window.",
);
const usage_message = usage: {
    @setEvalBranchQuota(2_000);
    break :usage std.unicode.utf8ToUtf16LeStringLiteral(
        "Usage: novella [-f FILE | - | --text TEXT]\n\n" ++
            "  -f FILE      Open UTF-8 text from a file\n" ++
            "  -             Read UTF-8 text from stdin\n" ++
            "  --text TEXT   Open literal UTF-8 text",
    );
};

const logical_width: c_int = 900;
const logical_height: c_int = 760;
const default_dpi: c_uint = 96;
const application_icon: win32.LPCWSTR = @ptrFromInt(32512);
const arrow_cursor: win32.LPCWSTR = @ptrFromInt(32512);

const windows_pixel_format = software.PixelFormat{
    .bits_per_pixel = 32,
    .scanline_pad = 32,
    .lsb_first = true,
    .red_mask = 0x00ff0000,
    .green_mask = 0x0000ff00,
    .blue_mask = 0x000000ff,
};

const App = struct {
    allocator: std.mem.Allocator,
    document: editing.Editor,
    caret_map: editing.CaretMap,
    utf16_decoder: utf16_input.Decoder = .{},
    scale: f64,
    font_bytes: []u8,
    text_engine: shaping.Engine,
    run_cache: software.RunCache,
    glyph_engine: software.GlyphEngine,
    background: software.Surface,
    surface: software.Surface,
    pending_width: u16 = 0,
    pending_height: u16 = 0,
    dirty: bool = true,
    render_failed: bool = false,

    fn create(allocator: std.mem.Allocator, text: []const u8, scale: f64) !*App {
        if (!(scale > 0) or !std.math.isFinite(scale)) return error.InvalidDisplayScale;
        const app = try allocator.create(App);
        errdefer allocator.destroy(app);
        var document = try editing.Editor.init(allocator, text);
        errdefer document.deinit();
        var caret_map = editing.CaretMap.init(allocator);
        errdefer caret_map.deinit();
        const font_bytes = try font_data.loadJunicode(allocator);
        errdefer allocator.free(font_bytes);
        const pixel_font_size = sheet.body_font_size * scale;
        var text_engine = try shaping.Engine.init(font_bytes, pixel_font_size);
        errdefer text_engine.deinit();
        var run_cache = software.RunCache.init(allocator, &text_engine);
        errdefer run_cache.deinit();
        var glyph_engine = try software.GlyphEngine.init(
            allocator,
            font_bytes,
            pixel_font_size,
        );
        errdefer glyph_engine.deinit();
        const surface = try software.Surface.init(allocator, windows_pixel_format);
        errdefer {
            var owned = surface;
            owned.deinit();
        }
        const background = try software.Surface.init(allocator, windows_pixel_format);
        errdefer {
            var owned = background;
            owned.deinit();
        }

        app.* = .{
            .allocator = allocator,
            .document = document,
            .caret_map = caret_map,
            .scale = scale,
            .font_bytes = font_bytes,
            .text_engine = text_engine,
            .run_cache = run_cache,
            .glyph_engine = glyph_engine,
            .background = background,
            .surface = surface,
        };
        app.run_cache.engine = &app.text_engine;
        return app;
    }

    fn destroy(self: *App) void {
        const allocator = self.allocator;
        self.surface.deinit();
        self.background.deinit();
        self.glyph_engine.deinit();
        self.run_cache.deinit();
        self.text_engine.deinit();
        allocator.free(self.font_bytes);
        self.caret_map.deinit();
        self.document.deinit();
        allocator.destroy(self);
    }

    fn queueResize(self: *App, width: u16, height: u16) void {
        self.pending_width = width;
        self.pending_height = height;
        self.dirty = true;
    }

    fn render(self: *App) !void {
        if (self.pending_width == 0 or self.pending_height == 0) return;
        const resized = self.surface.width != self.pending_width or
            self.surface.height != self.pending_height;
        if (resized) {
            try self.surface.resize(self.pending_width, self.pending_height);
            try self.background.resize(self.pending_width, self.pending_height);
            self.background.paintSheet(self.scale);
        }
        if (!self.dirty) return;
        @memcpy(self.surface.pixels, self.background.pixels);
        try software.paintEditorContent(
            &self.surface,
            &self.document,
            &self.caret_map,
            &self.run_cache,
            &self.glyph_engine,
            self.scale,
        );
        self.dirty = false;
    }
};

pub fn main(init: std.process.Init) void {
    run(init) catch {
        _ = win32.MessageBoxW(
            null,
            failure_message,
            failure_title,
            win32.MB_OK | win32.MB_ICONERROR,
        );
    };
}

fn run(init: std.process.Init) !void {
    const initial_text = try loadInitialText(init);
    const allocator = std.heap.smp_allocator;
    const dpi = systemDpi();
    const scale = @as(f64, @floatFromInt(dpi)) / default_dpi;
    const app = try App.create(allocator, initial_text, scale);
    defer app.destroy();

    const instance = win32.GetModuleHandleW(null) orelse
        return error.ModuleHandleUnavailable;

    const window_class = win32.WNDCLASSEXW{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = 0,
        // Zig 0.16 translate-c drops CALLBACK on the x86 WNDPROC typedef.
        .lpfnWndProc = @ptrCast(&windowProcedure),
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = win32.LoadIconW(null, application_icon),
        .hCursor = win32.LoadCursorW(null, arrow_cursor),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = win32.LoadIconW(null, application_icon),
    };
    if (win32.RegisterClassExW(&window_class) == 0)
        return error.WindowClassRegistrationFailed;
    defer _ = win32.UnregisterClassW(class_name, instance);

    var frame = win32.RECT{
        .left = 0,
        .top = 0,
        .right = scaleForDpi(logical_width, dpi),
        .bottom = scaleForDpi(logical_height, dpi),
    };
    const style = win32.WS_OVERLAPPEDWINDOW;
    if (win32.AdjustWindowRectEx(&frame, style, 0, 0) == 0)
        return error.WindowFrameUnavailable;

    const window = win32.CreateWindowExW(
        0,
        class_name,
        window_title,
        style,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        frame.right - frame.left,
        frame.bottom - frame.top,
        null,
        null,
        instance,
        app,
    ) orelse return error.WindowCreationFailed;
    defer _ = win32.DestroyWindow(window);

    queueClientSize(window, app);
    _ = win32.ShowWindow(window, win32.SW_SHOWDEFAULT);
    if (win32.UpdateWindow(window) == 0)
        return error.WindowUpdateFailed;
    if (app.render_failed) return error.InitialRenderFailed;

    var event: win32.MSG = undefined;
    while (true) {
        const result = win32.GetMessageW(&event, null, 0, 0);
        if (result == -1) return error.MessageLoopFailed;
        if (result == 0) break;
        _ = win32.TranslateMessage(&event);
        _ = win32.DispatchMessageW(&event);
    }
    if (app.render_failed) return error.RenderFailed;
}

fn windowProcedure(
    window: win32.HWND,
    message: c_uint,
    word_param: win32.WPARAM,
    long_param: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    switch (message) {
        win32.WM_NCCREATE => {
            const create: *const win32.CREATESTRUCTW =
                @ptrFromInt(@as(usize, @bitCast(long_param)));
            const user_data = create.lpCreateParams orelse return 0;
            const app: *App = @ptrCast(@alignCast(user_data));
            _ = win32.SetWindowLongPtrW(
                window,
                win32.GWLP_USERDATA,
                @as(win32.LONG_PTR, @bitCast(@intFromPtr(app))),
            );
            return 1;
        },
        win32.WM_SIZE => {
            if (appForWindow(window)) |app| queueClientSize(window, app);
            _ = win32.InvalidateRect(window, null, 0);
            return 0;
        },
        win32.WM_KEYDOWN => {
            if (appForWindow(window)) |app| {
                if (handleVirtualKey(app, word_param, long_param)) {
                    requestRepaint(window, app);
                    return 0;
                }
            }
            return win32.DefWindowProcW(window, message, word_param, long_param);
        },
        win32.WM_CHAR => {
            if (appForWindow(window)) |app| {
                handleCharacter(app, word_param, long_param);
                requestRepaint(window, app);
            }
            return 0;
        },
        win32.WM_ERASEBKGND => return 1,
        win32.WM_PAINT => {
            var paint: win32.PAINTSTRUCT = undefined;
            const device_context = win32.BeginPaint(window, &paint);
            if (device_context != null) {
                paintWindow(appForWindow(window), device_context) catch {
                    if (appForWindow(window)) |app| app.render_failed = true;
                    _ = win32.FillRect(
                        device_context,
                        &paint.rcPaint,
                        win32.GetSysColorBrush(win32.COLOR_WINDOW),
                    );
                    if (win32.PostMessageW(window, win32.WM_CLOSE, 0, 0) == 0)
                        win32.PostQuitMessage(1);
                };
                _ = win32.EndPaint(window, &paint);
            }
            return 0;
        },
        win32.WM_DESTROY => {
            win32.PostQuitMessage(0);
            return 0;
        },
        win32.WM_NCDESTROY => {
            _ = win32.SetWindowLongPtrW(window, win32.GWLP_USERDATA, 0);
            return win32.DefWindowProcW(window, message, word_param, long_param);
        },
        else => return win32.DefWindowProcW(window, message, word_param, long_param),
    }
}

fn handleVirtualKey(
    app: *App,
    word_param: win32.WPARAM,
    long_param: win32.LPARAM,
) bool {
    const key: c_uint = @truncate(word_param);
    const repeat_count = utf16_input.messageRepeatCount(
        @as(usize, @bitCast(long_param)),
    );
    switch (key) {
        win32.VK_LEFT => for (0..repeat_count) |_| {
            recordEdit(app, app.document.moveLeft(&app.caret_map));
        },
        win32.VK_RIGHT => for (0..repeat_count) |_| {
            recordEdit(app, app.document.moveRight(&app.caret_map));
        },
        win32.VK_UP => for (0..repeat_count) |_| {
            recordEdit(app, app.document.moveVertical(&app.caret_map, .up));
        },
        win32.VK_DOWN => for (0..repeat_count) |_| {
            recordEdit(app, app.document.moveVertical(&app.caret_map, .down));
        },
        win32.VK_BACK => for (0..repeat_count) |_| {
            recordEdit(app, app.document.backspace(&app.caret_map));
        },
        win32.VK_DELETE => for (0..repeat_count) |_| {
            recordEdit(app, app.document.deleteForward(&app.caret_map));
        },
        else => return false,
    }
    app.utf16_decoder.reset();
    return true;
}

fn handleCharacter(
    app: *App,
    word_param: win32.WPARAM,
    long_param: win32.LPARAM,
) void {
    const code_unit: u16 = @truncate(word_param);
    const repeat_count = utf16_input.messageRepeatCount(
        @as(usize, @bitCast(long_param)),
    );
    if (code_unit == '\r') {
        app.utf16_decoder.reset();
        recordEdit(app, app.document.insertRepeated("\n", repeat_count));
        return;
    }
    // Backspace is handled from WM_KEYDOWN so it is applied exactly once.
    if (code_unit == '\x08') {
        app.utf16_decoder.reset();
        return;
    }
    if (code_unit < 0x20 and code_unit != '\t') {
        app.utf16_decoder.reset();
        return;
    }

    const codepoint = app.utf16_decoder.push(code_unit) orelse return;
    var encoded: [4]u8 = undefined;
    const encoded_len = std.unicode.utf8Encode(codepoint, &encoded) catch return;
    recordEdit(app, app.document.insertRepeated(encoded[0..encoded_len], repeat_count));
}

fn recordEdit(app: *App, result: anyerror!bool) void {
    _ = result catch {
        app.render_failed = true;
        return;
    };
}

fn requestRepaint(window: win32.HWND, app: *App) void {
    app.dirty = true;
    _ = win32.InvalidateRect(window, null, 0);
}

fn appForWindow(window: win32.HWND) ?*App {
    const value = win32.GetWindowLongPtrW(window, win32.GWLP_USERDATA);
    if (value == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(value)));
}

fn queueClientSize(window: win32.HWND, app: *App) void {
    var client: win32.RECT = undefined;
    if (win32.GetClientRect(window, &client) == 0) return;
    app.queueResize(clientExtent(client.right - client.left), clientExtent(client.bottom - client.top));
}

fn clientExtent(value: c_long) u16 {
    if (value <= 0) return 0;
    return @intCast(@min(@as(u32, @intCast(value)), std.math.maxInt(u16)));
}

fn paintWindow(app: ?*App, device_context: win32.HDC) !void {
    const state = app orelse return error.WindowStateUnavailable;
    try state.render();
    if (state.surface.width == 0 or state.surface.height == 0) return;

    var bitmap: win32.BITMAPINFO = std.mem.zeroInit(win32.BITMAPINFO, .{});
    bitmap.bmiHeader.biSize = @sizeOf(win32.BITMAPINFOHEADER);
    bitmap.bmiHeader.biWidth = @intCast(state.surface.width);
    bitmap.bmiHeader.biHeight = -@as(c_long, @intCast(state.surface.height));
    bitmap.bmiHeader.biPlanes = 1;
    bitmap.bmiHeader.biBitCount = 32;
    bitmap.bmiHeader.biCompression = win32.BI_RGB;

    if (win32.SetDIBitsToDevice(
        device_context,
        0,
        0,
        state.surface.width,
        state.surface.height,
        0,
        0,
        0,
        state.surface.height,
        state.surface.pixels.ptr,
        &bitmap,
        win32.DIB_RGB_COLORS,
    ) == 0) return error.FramePresentationFailed;
}

fn systemDpi() c_uint {
    const device_context = win32.GetDC(null) orelse return default_dpi;
    defer _ = win32.ReleaseDC(null, device_context);
    const dpi = win32.GetDeviceCaps(device_context, win32.LOGPIXELSX);
    return if (dpi > 0) @intCast(dpi) else default_dpi;
}

fn scaleForDpi(value: c_int, dpi: c_uint) c_int {
    return win32.MulDiv(value, @intCast(dpi), default_dpi);
}

fn loadInitialText(init: std.process.Init) ![]const u8 {
    const allocator = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(allocator);
    if (arguments.len == 1) return "";
    if (std.mem.eql(u8, arguments[1], "-h") or std.mem.eql(u8, arguments[1], "--help")) {
        _ = win32.MessageBoxW(null, usage_message, window_title, win32.MB_OK);
        std.process.exit(0);
    }

    var contents: []const u8 = undefined;
    if (std.mem.eql(u8, arguments[1], "-f")) {
        if (arguments.len < 3) return error.MissingFileArgument;
        contents = try std.Io.Dir.cwd().readFileAlloc(
            init.io,
            arguments[2],
            allocator,
            .limited(editing.max_text_bytes + 1),
        );
    } else if (std.mem.eql(u8, arguments[1], "-")) {
        var input_buffer: [4096]u8 = undefined;
        var input = std.Io.File.stdin().reader(init.io, &input_buffer);
        contents = try input.interface.allocRemaining(
            allocator,
            .limited(editing.max_text_bytes + 1),
        );
    } else if (std.mem.eql(u8, arguments[1], "--text")) {
        if (arguments.len < 3) return error.MissingTextArgument;
        contents = arguments[2];
    } else {
        return error.UnknownArgument;
    }

    if (contents.len > editing.max_text_bytes) return error.InputTooLong;
    if (!std.unicode.utf8ValidateSlice(contents)) return error.InvalidUtf8;
    return contents;
}
