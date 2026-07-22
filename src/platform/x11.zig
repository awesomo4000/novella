// SPDX-License-Identifier: MPL-2.0

const xcb = @cImport({
    @cInclude("stdlib.h");
    @cInclude("xcb.h");
});

pub fn main() !void {
    var screen_number: c_int = 0;
    const connection = xcb.xcb_connect(null, &screen_number) orelse
        return error.X11ConnectionFailed;
    defer xcb.xcb_disconnect(connection);

    if (xcb.xcb_connection_has_error(connection) != 0)
        return error.X11ConnectionFailed;

    const setup = xcb.xcb_get_setup(connection) orelse
        return error.X11SetupUnavailable;
    var screens = xcb.xcb_setup_roots_iterator(setup);
    var index: c_int = 0;
    while (index < screen_number and screens.rem > 0) : (index += 1)
        xcb.xcb_screen_next(&screens);
    const screen = screens.data orelse return error.X11ScreenUnavailable;

    const window = xcb.xcb_generate_id(connection);
    const event_mask: u32 = xcb.XCB_EVENT_MASK_EXPOSURE |
        xcb.XCB_EVENT_MASK_KEY_PRESS |
        xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY;
    const values = [_]u32{ screen.*.white_pixel, event_mask };
    const value_mask: u32 = xcb.XCB_CW_BACK_PIXEL | xcb.XCB_CW_EVENT_MASK;

    _ = xcb.xcb_create_window(
        connection,
        xcb.XCB_COPY_FROM_PARENT,
        window,
        screen.*.root,
        0,
        0,
        640,
        420,
        0,
        xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT,
        screen.*.root_visual,
        value_mask,
        &values,
    );

    const title = "Novella X11 — vendored static XCB";
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
    _ = xcb.xcb_map_window(connection, window);
    if (xcb.xcb_flush(connection) <= 0) return error.X11FlushFailed;

    while (true) {
        const event = xcb.xcb_wait_for_event(connection) orelse break;
        const event_type = event.*.response_type & 0x7f;
        xcb.free(event);
        if (event_type == xcb.XCB_KEY_PRESS or event_type == xcb.XCB_DESTROY_NOTIFY)
            break;
    }
}
