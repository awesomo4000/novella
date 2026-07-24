// SPDX-License-Identifier: MPL-2.0

const std = @import("std");

const c = @cImport({
    @cInclude("locale.h");
    @cInclude("stdlib.h");
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/xkb.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xkbcommon/xkbcommon-compose.h");
    @cInclude("xkbcommon/xkbcommon-keysyms.h");
    @cInclude("xkbcommon/xkbcommon-x11.h");
});
pub const xcb = c;

pub const Kind = enum {
    none,
    text,
    paragraph,
    move_left,
    move_right,
    move_up,
    move_down,
    delete_backward,
    delete_forward,
    quit,
};

pub const Input = struct {
    kind: Kind = .none,
    bytes: [64]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const Input) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Keyboard = struct {
    connection: *c.xcb_connection_t,
    context: *c.xkb_context,
    keymap: *c.xkb_keymap,
    state: *c.xkb_state,
    compose_table: ?*c.xkb_compose_table,
    compose_state: ?*c.xkb_compose_state,
    device_id: i32,
    first_xkb_event: u8,

    pub fn init(connection: *c.xcb_connection_t) !Keyboard {
        var first_event: u8 = 0;
        if (c.xkb_x11_setup_xkb_extension(
            connection,
            c.XKB_X11_MIN_MAJOR_XKB_VERSION,
            c.XKB_X11_MIN_MINOR_XKB_VERSION,
            c.XKB_X11_SETUP_XKB_EXTENSION_NO_FLAGS,
            null,
            null,
            &first_event,
            null,
        ) != 1) return error.XkbExtensionUnavailable;

        const context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse
            return error.XkbContextUnavailable;
        errdefer c.xkb_context_unref(context);

        const device_id = c.xkb_x11_get_core_keyboard_device_id(connection);
        if (device_id < 0) return error.XkbKeyboardUnavailable;
        const keymap = c.xkb_x11_keymap_new_from_device(
            context,
            connection,
            device_id,
            c.XKB_KEYMAP_COMPILE_NO_FLAGS,
        ) orelse return error.XkbKeymapUnavailable;
        errdefer c.xkb_keymap_unref(keymap);
        const state = c.xkb_x11_state_new_from_device(keymap, connection, device_id) orelse
            return error.XkbStateUnavailable;
        errdefer c.xkb_state_unref(state);

        _ = c.setlocale(c.LC_CTYPE, "");
        const locale = c.setlocale(c.LC_CTYPE, null);
        const compose_table = if (locale) |name|
            c.xkb_compose_table_new_from_locale(
                context,
                name,
                c.XKB_COMPOSE_COMPILE_NO_FLAGS,
            )
        else
            null;
        errdefer if (compose_table) |table| c.xkb_compose_table_unref(table);
        const compose_state = if (compose_table) |table|
            c.xkb_compose_state_new(table, c.XKB_COMPOSE_STATE_NO_FLAGS)
        else
            null;
        errdefer if (compose_state) |value| c.xkb_compose_state_unref(value);

        try selectEvents(connection, device_id);
        return .{
            .connection = connection,
            .context = context,
            .keymap = keymap,
            .state = state,
            .compose_table = compose_table,
            .compose_state = compose_state,
            .device_id = device_id,
            .first_xkb_event = first_event,
        };
    }

    pub fn deinit(self: *Keyboard) void {
        c.xkb_state_unref(self.state);
        if (self.compose_state) |value| c.xkb_compose_state_unref(value);
        if (self.compose_table) |value| c.xkb_compose_table_unref(value);
        c.xkb_keymap_unref(self.keymap);
        c.xkb_context_unref(self.context);
        self.* = undefined;
    }

    pub fn isXkbEvent(self: *const Keyboard, event_type: u8) bool {
        return event_type == self.first_xkb_event;
    }

    pub fn processXkbEvent(self: *Keyboard, event: *const c.xcb_generic_event_t) !void {
        const any: *const XkbAnyEvent = @ptrCast(event);
        if (any.device_id != self.device_id) return;
        switch (any.xkb_type) {
            c.XCB_XKB_NEW_KEYBOARD_NOTIFY => {
                const notification: *const c.xcb_xkb_new_keyboard_notify_event_t = @ptrCast(event);
                if (notification.changed & c.XCB_XKB_NKN_DETAIL_KEYCODES != 0)
                    try self.updateKeymap();
            },
            c.XCB_XKB_MAP_NOTIFY => try self.updateKeymap(),
            c.XCB_XKB_STATE_NOTIFY => {
                const notification: *const c.xcb_xkb_state_notify_event_t = @ptrCast(event);
                _ = c.xkb_state_update_mask(
                    self.state,
                    notification.baseMods,
                    notification.latchedMods,
                    notification.lockedMods,
                    signedGroup(notification.baseGroup),
                    signedGroup(notification.latchedGroup),
                    notification.lockedGroup,
                );
            },
            else => {},
        }
    }

    pub fn translateKeyPress(self: *Keyboard, keycode: u8) Input {
        const symbol = c.xkb_state_key_get_one_sym(self.state, keycode);
        const control = self.modifierActive("Control");
        const logo = self.modifierActive("Mod4");
        if (control or logo) {
            if (symbol == c.XKB_KEY_q or symbol == c.XKB_KEY_Q)
                return .{ .kind = .quit };
            self.resetCompose();
            return .{};
        }

        const special: Kind = switch (symbol) {
            c.XKB_KEY_Left => .move_left,
            c.XKB_KEY_Right => .move_right,
            c.XKB_KEY_Up => .move_up,
            c.XKB_KEY_Down => .move_down,
            c.XKB_KEY_BackSpace => .delete_backward,
            c.XKB_KEY_Delete => .delete_forward,
            c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => .paragraph,
            else => .none,
        };
        if (special != .none) {
            self.resetCompose();
            return .{ .kind = special };
        }

        var input = Input{};
        if (self.compose_state) |compose| {
            _ = c.xkb_compose_state_feed(compose, symbol);
            switch (c.xkb_compose_state_get_status(compose)) {
                c.XKB_COMPOSE_COMPOSING => return input,
                c.XKB_COMPOSE_COMPOSED => {
                    input.len = utf8FromCompose(compose, &input.bytes);
                    c.xkb_compose_state_reset(compose);
                },
                c.XKB_COMPOSE_CANCELLED => {
                    c.xkb_compose_state_reset(compose);
                    input.len = utf8FromState(self.state, keycode, &input.bytes);
                },
                else => input.len = utf8FromState(self.state, keycode, &input.bytes),
            }
        } else {
            input.len = utf8FromState(self.state, keycode, &input.bytes);
        }
        if (input.len > 0 and (input.bytes[0] >= 0x20 or input.bytes[0] == '\t'))
            input.kind = .text
        else
            input.len = 0;
        return input;
    }

    fn updateKeymap(self: *Keyboard) !void {
        const keymap = c.xkb_x11_keymap_new_from_device(
            self.context,
            self.connection,
            self.device_id,
            c.XKB_KEYMAP_COMPILE_NO_FLAGS,
        ) orelse return error.XkbKeymapUnavailable;
        errdefer c.xkb_keymap_unref(keymap);
        const state = c.xkb_x11_state_new_from_device(
            keymap,
            self.connection,
            self.device_id,
        ) orelse return error.XkbStateUnavailable;

        c.xkb_state_unref(self.state);
        c.xkb_keymap_unref(self.keymap);
        self.keymap = keymap;
        self.state = state;
        self.resetCompose();
    }

    fn modifierActive(self: *const Keyboard, name: [*:0]const u8) bool {
        return c.xkb_state_mod_name_is_active(
            self.state,
            name,
            c.XKB_STATE_MODS_EFFECTIVE,
        ) > 0;
    }

    fn resetCompose(self: *Keyboard) void {
        if (self.compose_state) |compose| c.xkb_compose_state_reset(compose);
    }
};

const XkbAnyEvent = extern struct {
    response_type: u8,
    xkb_type: u8,
    sequence: u16,
    time: u32,
    device_id: u8,
};

fn selectEvents(connection: *c.xcb_connection_t, device_id: i32) !void {
    const events: u16 = c.XCB_XKB_EVENT_TYPE_NEW_KEYBOARD_NOTIFY |
        c.XCB_XKB_EVENT_TYPE_MAP_NOTIFY |
        c.XCB_XKB_EVENT_TYPE_STATE_NOTIFY;
    const map_parts: u16 = c.XCB_XKB_MAP_PART_KEY_TYPES |
        c.XCB_XKB_MAP_PART_KEY_SYMS |
        c.XCB_XKB_MAP_PART_MODIFIER_MAP |
        c.XCB_XKB_MAP_PART_EXPLICIT_COMPONENTS |
        c.XCB_XKB_MAP_PART_KEY_ACTIONS |
        c.XCB_XKB_MAP_PART_VIRTUAL_MODS |
        c.XCB_XKB_MAP_PART_VIRTUAL_MOD_MAP;
    const new_keyboard_details: u16 = c.XCB_XKB_NKN_DETAIL_KEYCODES;
    const state_details: u16 = c.XCB_XKB_STATE_PART_MODIFIER_BASE |
        c.XCB_XKB_STATE_PART_MODIFIER_LATCH |
        c.XCB_XKB_STATE_PART_MODIFIER_LOCK |
        c.XCB_XKB_STATE_PART_GROUP_BASE |
        c.XCB_XKB_STATE_PART_GROUP_LATCH |
        c.XCB_XKB_STATE_PART_GROUP_LOCK;
    const details = c.xcb_xkb_select_events_details_t{
        .affectNewKeyboard = new_keyboard_details,
        .newKeyboardDetails = new_keyboard_details,
        .affectState = state_details,
        .stateDetails = state_details,
        .affectCtrls = 0,
        .ctrlDetails = 0,
        .affectIndicatorState = 0,
        .indicatorStateDetails = 0,
        .affectIndicatorMap = 0,
        .indicatorMapDetails = 0,
        .affectNames = 0,
        .namesDetails = 0,
        .affectCompat = 0,
        .compatDetails = 0,
        .affectBell = 0,
        .bellDetails = 0,
        .affectMsgDetails = 0,
        .msgDetails = 0,
        .affectAccessX = 0,
        .accessXDetails = 0,
        .affectExtDev = 0,
        .extdevDetails = 0,
    };
    const cookie = c.xcb_xkb_select_events_aux_checked(
        connection,
        @intCast(device_id),
        events,
        0,
        0,
        map_parts,
        map_parts,
        &details,
    );
    if (c.xcb_request_check(connection, cookie)) |xcb_error| {
        c.free(xcb_error);
        return error.XkbEventSelectionFailed;
    }
}

fn utf8FromState(state: *c.xkb_state, keycode: u8, destination: *[64]u8) usize {
    const count = c.xkb_state_key_get_utf8(state, keycode, destination, destination.len);
    if (count <= 0 or count >= destination.len) return 0;
    return @intCast(count);
}

fn utf8FromCompose(compose: *c.xkb_compose_state, destination: *[64]u8) usize {
    const count = c.xkb_compose_state_get_utf8(compose, destination, destination.len);
    if (count <= 0 or count >= destination.len) return 0;
    return @intCast(count);
}

fn signedGroup(group: i16) u32 {
    return @bitCast(@as(i32, group));
}
