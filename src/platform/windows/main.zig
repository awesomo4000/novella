// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const win32 = @import("win32.zig").api;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("NovellaWindow");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("Novella");
const failure_title = std.unicode.utf8ToUtf16LeStringLiteral("Novella could not start");
const failure_message = std.unicode.utf8ToUtf16LeStringLiteral("Windows could not create the Novella window.");

const logical_width = 900;
const logical_height = 760;
const default_dpi = 96;
const application_icon: win32.LPCWSTR = @ptrFromInt(32512);
const arrow_cursor: win32.LPCWSTR = @ptrFromInt(32512);

pub fn main() void {
    run() catch {
        _ = win32.MessageBoxW(
            null,
            failure_message,
            failure_title,
            win32.MB_OK | win32.MB_ICONERROR,
        );
    };
}

fn run() !void {
    const instance = win32.GetModuleHandleW(null) orelse
        return error.ModuleHandleUnavailable;

    const window_class = win32.WNDCLASSEXW{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = win32.CS_HREDRAW | win32.CS_VREDRAW,
        .lpfnWndProc = windowProcedure,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = win32.LoadIconW(null, application_icon),
        .hCursor = win32.LoadCursorW(null, arrow_cursor),
        .hbrBackground = win32.GetSysColorBrush(win32.COLOR_WINDOW),
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = win32.LoadIconW(null, application_icon),
    };
    if (win32.RegisterClassExW(&window_class) == 0)
        return error.WindowClassRegistrationFailed;
    defer _ = win32.UnregisterClassW(class_name, instance);

    const dpi: c_uint = win32.GetDpiForSystem();
    var frame = win32.RECT{
        .left = 0,
        .top = 0,
        .right = scaleForDpi(logical_width, dpi),
        .bottom = scaleForDpi(logical_height, dpi),
    };
    const style = win32.WS_OVERLAPPEDWINDOW;
    if (win32.AdjustWindowRectExForDpi(&frame, style, 0, 0, dpi) == 0)
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
        null,
    ) orelse return error.WindowCreationFailed;

    _ = win32.ShowWindow(window, win32.SW_SHOWDEFAULT);
    if (win32.UpdateWindow(window) == 0)
        return error.WindowUpdateFailed;

    var event: win32.MSG = undefined;
    while (true) {
        const result = win32.GetMessageW(&event, null, 0, 0);
        if (result == -1) return error.MessageLoopFailed;
        if (result == 0) break;
        _ = win32.TranslateMessage(&event);
        _ = win32.DispatchMessageW(&event);
    }
}

fn scaleForDpi(value: c_int, dpi: c_uint) c_int {
    return win32.MulDiv(value, @intCast(dpi), default_dpi);
}

fn windowProcedure(
    window: win32.HWND,
    message: c_uint,
    word_param: win32.WPARAM,
    long_param: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    switch (message) {
        win32.WM_DPICHANGED => {
            const suggested: *const win32.RECT = @ptrFromInt(@as(usize, @bitCast(long_param)));
            _ = win32.SetWindowPos(
                window,
                null,
                suggested.left,
                suggested.top,
                suggested.right - suggested.left,
                suggested.bottom - suggested.top,
                win32.SWP_NOACTIVATE | win32.SWP_NOZORDER,
            );
            return 0;
        },
        win32.WM_PAINT => {
            var paint: win32.PAINTSTRUCT = undefined;
            const device_context = win32.BeginPaint(window, &paint);
            if (device_context != null) {
                _ = win32.FillRect(
                    device_context,
                    &paint.rcPaint,
                    win32.GetSysColorBrush(win32.COLOR_WINDOW),
                );
                _ = win32.EndPaint(window, &paint);
            }
            return 0;
        },
        win32.WM_DESTROY => {
            win32.PostQuitMessage(0);
            return 0;
        },
        else => return win32.DefWindowProcW(window, message, word_param, long_param),
    }
}
