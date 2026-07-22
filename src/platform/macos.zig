// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const builtin = @import("builtin");
const novella = @import("novella");
const shaping = @import("text_engine");
const font_data = @import("font_data");

const Obj = ?*anyopaque;
const Sel = ?*anyopaque;

const Point = extern struct { x: f64, y: f64 };
const Size = extern struct { width: f64, height: f64 };
const Rect = extern struct { origin: Point, size: Size };
const AffineTransform = extern struct { a: f64, b: f64, c: f64, d: f64, tx: f64, ty: f64 };

extern fn objc_getClass(name: [*:0]const u8) Obj;
extern fn sel_registerName(name: [*:0]const u8) Sel;
extern fn objc_allocateClassPair(superclass: Obj, name: [*:0]const u8, extra_bytes: usize) Obj;
extern fn objc_registerClassPair(cls: Obj) void;
extern fn class_addMethod(cls: Obj, name: Sel, implementation: *const anyopaque, types: [*:0]const u8) bool;
extern fn objc_msgSend() void;
extern fn objc_msgSend_stret() void;

extern fn CFDataCreate(allocator: Obj, bytes: [*]const u8, length: isize) Obj;
extern fn CFStringCreateWithBytes(allocator: Obj, bytes: [*]const u8, length: isize, encoding: u32, external: u8) Obj;
extern fn CFRelease(value: Obj) void;

extern fn CGDataProviderCreateWithCFData(data: Obj) Obj;
extern fn CGDataProviderRelease(provider: Obj) void;
extern fn CGFontCreateWithDataProvider(provider: Obj) Obj;
extern fn CGFontRelease(font: Obj) void;
extern fn CGColorCreateGenericRGB(red: f64, green: f64, blue: f64, alpha: f64) Obj;
extern fn CGColorRelease(color: Obj) void;

extern fn CGContextSaveGState(context: Obj) void;
extern fn CGContextRestoreGState(context: Obj) void;
extern fn CGContextSetRGBFillColor(context: Obj, red: f64, green: f64, blue: f64, alpha: f64) void;
extern fn CGContextSetRGBStrokeColor(context: Obj, red: f64, green: f64, blue: f64, alpha: f64) void;
extern fn CGContextSetLineWidth(context: Obj, width: f64) void;
extern fn CGContextFillRect(context: Obj, rect: Rect) void;
extern fn CGContextStrokeRect(context: Obj, rect: Rect) void;
extern fn CGContextSetShadowWithColor(context: Obj, offset: Size, blur: f64, color: Obj) void;
extern fn CGContextSetTextMatrix(context: Obj, transform: AffineTransform) void;

extern fn CTFontCreateWithGraphicsFont(graphics_font: Obj, size: f64, matrix: ?*const AffineTransform, attributes: Obj) Obj;
extern fn CTFontDrawGlyphs(font: Obj, glyphs: [*]const u16, positions: [*]const Point, count: usize, context: Obj) void;

const utf8_encoding: u32 = 0x0800_0100;
const identity = AffineTransform{ .a = 1, .b = 0, .c = 0, .d = 1, .tx = 0, .ty = 0 };

const max_text_bytes = 64 * 1024;
const line_height = 27.2;
const body_font_size = 18.5;

const State = struct {
    view: Obj = null,
    body_font: Obj = null,
    font_bytes: ?[]u8 = null,
    text_engine: ?shaping.Engine = null,
    typed: [max_text_bytes]u8 = undefined,
    typed_len: usize = 0,
    cursor: usize = 0,
    preferred_x: f64 = 0,
    preferred_x_active: bool = false,
    caret_stops: [max_text_bytes + 1]CaretStop = undefined,
    caret_stop_count: usize = 0,
    document_revision: u64 = 1,
    caret_revision: u64 = 0,
};

const CaretStop = struct {
    offset: usize,
    x: f64,
    y: f64,
};

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

var app_state: State = .{};

pub fn main(init: std.process.Init) !void {
    if (!try loadInitialText(init)) return;

    const pool = send0(send0(objc_getClass("NSAutoreleasePool"), "alloc"), "init");
    defer sendVoid0(pool, "drain");

    try prepareFonts(std.heap.smp_allocator);
    defer releaseFonts(std.heap.smp_allocator);
    try registerClasses();

    const app = send0(objc_getClass("NSApplication"), "sharedApplication");
    _ = sendInteger(app, "setActivationPolicy:", 0);
    installApplicationMenu(app);

    const delegate = send0(send0(objc_getClass("NovellaDelegate"), "alloc"), "init");
    sendVoidObj(app, "setDelegate:", delegate);

    const frame = Rect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 900, .height = 760 } };
    const window_class = objc_getClass("NSWindow");
    const window = sendWindowInit(send0(window_class, "alloc"), frame, 15, 2, 0);
    const window_title = makeString("Novella — a justified writing sheet");
    defer CFRelease(window_title);
    sendVoidObj(window, "setTitle:", window_title);
    sendVoid0(window, "center");
    sendVoidBool(window, "setReleasedWhenClosed:", 0);

    const view = sendRect(send0(objc_getClass("NovellaView"), "alloc"), "initWithFrame:", frame);
    app_state.view = view;
    sendVoidObj(window, "setContentView:", view);
    sendVoidObj(window, "makeFirstResponder:", view);
    sendVoidObj(window, "makeKeyAndOrderFront:", null);
    sendVoidBool(app, "activateIgnoringOtherApps:", 1);

    sendVoid0(app, "run");
}

fn loadInitialText(init: std.process.Init) !bool {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    if (arguments.len == 1) {
        setInitialText("");
        return true;
    }

    if (std.mem.eql(u8, arguments[1], "-h") or std.mem.eql(u8, arguments[1], "--help")) {
        var output_buffer: [1024]u8 = undefined;
        var output = std.Io.File.stdout().writer(init.io, &output_buffer);
        try output.interface.writeAll(
            \\Usage: novella [-f FILE | - | --text TEXT]
            \\
            \\  -f FILE      Open UTF-8 text from a file
            \\  -             Read UTF-8 text from stdin
            \\  --text TEXT   Open literal UTF-8 text
            \\
        );
        try output.interface.flush();
        return false;
    }

    var contents: []const u8 = undefined;
    if (std.mem.eql(u8, arguments[1], "-f")) {
        if (arguments.len < 3) return error.MissingFileArgument;
        contents = try std.Io.Dir.cwd().readFileAlloc(
            init.io,
            arguments[2],
            arena,
            .limited(max_text_bytes + 1),
        );
    } else if (std.mem.eql(u8, arguments[1], "-")) {
        var input_buffer: [4096]u8 = undefined;
        var input = std.Io.File.stdin().reader(init.io, &input_buffer);
        contents = try input.interface.allocRemaining(arena, .limited(max_text_bytes + 1));
    } else if (std.mem.eql(u8, arguments[1], "--text")) {
        if (arguments.len < 3) return error.MissingTextArgument;
        contents = arguments[2];
    } else {
        return error.UnknownArgument;
    }

    if (contents.len > max_text_bytes) return error.InputTooLong;
    if (!std.unicode.utf8ValidateSlice(contents)) return error.InvalidUtf8;
    setInitialText(contents);
    return true;
}

fn setInitialText(text: []const u8) void {
    var source_index: usize = 0;
    var destination_index: usize = 0;
    while (source_index < text.len) : (source_index += 1) {
        if (text[source_index] == '\r') {
            app_state.typed[destination_index] = '\n';
            destination_index += 1;
            if (source_index + 1 < text.len and text[source_index + 1] == '\n') source_index += 1;
        } else {
            app_state.typed[destination_index] = text[source_index];
            destination_index += 1;
        }
    }
    app_state.typed_len = destination_index;
    app_state.cursor = destination_index;
}

fn installApplicationMenu(app: Obj) void {
    const main_menu = send0(send0(objc_getClass("NSMenu"), "alloc"), "init");
    const app_item = send0(send0(objc_getClass("NSMenuItem"), "alloc"), "init");
    sendVoidObj(main_menu, "addItem:", app_item);

    const menu_title = makeString("Novella");
    defer CFRelease(menu_title);
    const app_menu = sendObj(send0(objc_getClass("NSMenu"), "alloc"), "initWithTitle:", menu_title);

    const quit_title = makeString("Quit Novella");
    defer CFRelease(quit_title);
    const quit_key = makeString("q");
    defer CFRelease(quit_key);
    const quit_item = sendMenuItemInit(
        send0(objc_getClass("NSMenuItem"), "alloc"),
        quit_title,
        selector("terminate:"),
        quit_key,
    );
    sendVoidObj(app_menu, "addItem:", quit_item);
    sendVoidObj(app_item, "setSubmenu:", app_menu);
    sendVoidObj(app, "setMainMenu:", main_menu);
}

fn prepareFonts(allocator: std.mem.Allocator) !void {
    const font_bytes = try font_data.loadJunicode(allocator);
    errdefer allocator.free(font_bytes);

    const data = CFDataCreate(null, font_bytes.ptr, @intCast(font_bytes.len));
    if (data == null) return error.FontDataUnavailable;
    defer CFRelease(data);
    const provider = CGDataProviderCreateWithCFData(data);
    if (provider == null) return error.FontProviderUnavailable;
    defer CGDataProviderRelease(provider);
    const graphics_font = CGFontCreateWithDataProvider(provider);
    if (graphics_font == null) return error.FontUnavailable;
    defer CGFontRelease(graphics_font);

    app_state.body_font = CTFontCreateWithGraphicsFont(graphics_font, body_font_size, null, null);
    if (app_state.body_font == null) return error.FontUnavailable;
    errdefer {
        CFRelease(app_state.body_font);
        app_state.body_font = null;
    }

    app_state.text_engine = try shaping.Engine.init(font_bytes, body_font_size);
    app_state.font_bytes = font_bytes;
}

fn releaseFonts(allocator: std.mem.Allocator) void {
    if (app_state.text_engine) |*engine| engine.deinit();
    app_state.text_engine = null;
    if (app_state.body_font != null) CFRelease(app_state.body_font);
    app_state.body_font = null;
    if (app_state.font_bytes) |font_bytes| allocator.free(font_bytes);
    app_state.font_bytes = null;
}

fn registerClasses() !void {
    const view_class = objc_allocateClassPair(objc_getClass("NSView"), "NovellaView", 0) orelse return error.ClassCreationFailed;
    if (!class_addMethod(view_class, selector("drawRect:"), @ptrCast(&drawRect), "v@:{CGRect={CGPoint=dd}{CGSize=dd}}")) return error.MethodCreationFailed;
    if (!class_addMethod(view_class, selector("acceptsFirstResponder"), @ptrCast(&acceptsFirstResponder), "c@:")) return error.MethodCreationFailed;
    if (!class_addMethod(view_class, selector("keyDown:"), @ptrCast(&keyDown), "v@:@")) return error.MethodCreationFailed;
    objc_registerClassPair(view_class);

    const delegate_class = objc_allocateClassPair(objc_getClass("NSObject"), "NovellaDelegate", 0) orelse return error.ClassCreationFailed;
    if (!class_addMethod(delegate_class, selector("applicationShouldTerminateAfterLastWindowClosed:"), @ptrCast(&terminateAfterClose), "c@:@")) return error.MethodCreationFailed;
    objc_registerClassPair(delegate_class);
}

fn drawRect(self: Obj, _: Sel, _: Rect) callconv(.c) void {
    const ns_context = send0(objc_getClass("NSGraphicsContext"), "currentContext");
    const context = send0(ns_context, "CGContext");
    if (context == null) return;
    const bounds = sendRect0(self, "bounds");

    CGContextSaveGState(context);
    defer CGContextRestoreGState(context);
    CGContextSetTextMatrix(context, identity);

    // Quiet neutral desktop; the paper itself stays actual white.
    CGContextSetRGBFillColor(context, 0.875, 0.882, 0.875, 1);
    CGContextFillRect(context, bounds);

    const paper_width = @min(646.0, @max(320.0, bounds.size.width - 86.0));
    const paper = Rect{
        .origin = .{ .x = (bounds.size.width - paper_width) / 2.0, .y = 20.0 },
        .size = .{ .width = paper_width, .height = @max(300.0, bounds.size.height - 34.0) },
    };
    const shadow = CGColorCreateGenericRGB(0.08, 0.09, 0.08, 0.22);
    if (shadow != null) {
        CGContextSetShadowWithColor(context, .{ .width = 0, .height = -3 }, 16, shadow);
        CGColorRelease(shadow);
    }
    CGContextSetRGBFillColor(context, 1, 1, 0.995, 1);
    CGContextFillRect(context, paper);
    CGContextSetShadowWithColor(context, .{ .width = 0, .height = 0 }, 0, null);
    CGContextSetRGBStrokeColor(context, 0.72, 0.73, 0.70, 0.55);
    CGContextSetLineWidth(context, 0.5);
    CGContextStrokeRect(context, paper);

    const left = paper.origin.x + @max(48.0, @min(74.0, paper.size.width * 0.115));
    const measure_width = paper.size.width - 2.0 * (left - paper.origin.x);
    var baseline = paper.origin.y + paper.size.height - 60.0;

    CGContextSetRGBFillColor(context, 0.095, 0.095, 0.09, 1);

    var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    const engine = if (app_state.text_engine) |*value| value else return;
    var frame_shaper = FrameShaper{ .allocator = allocator, .engine = engine };
    defer frame_shaper.deinit();
    const shown = app_state.typed[0..app_state.typed_len];

    app_state.caret_stop_count = 0;
    var paragraph_start: usize = 0;
    var caret_x = left;
    var caret_y = baseline;
    addCaretStop(0, caret_x, caret_y);
    while (paragraph_start <= shown.len) {
        const rest = shown[paragraph_start..];
        const separator = std.mem.indexOfScalar(u8, rest, '\n');
        const paragraph_end = if (separator) |offset| paragraph_start + offset else shown.len;
        const paragraph = shown[paragraph_start..paragraph_end];
        if (paragraph.len > 0) {
            var layout = novella.Layout.init(
                allocator,
                paragraph,
                measure_width,
                .{ .context = &frame_shaper, .measure_fn = measureBodyText },
                .{},
            ) catch break;
            defer layout.deinit(allocator);

            for (layout.lines) |line| {
                if (baseline < paper.origin.y + 62.0) break;
                var x = left;
                const line_words = layout.words[line.word_start..line.word_end];
                for (line_words, 0..) |word, index| {
                    const word_start = paragraph_start + sliceOffset(paragraph, word.text);
                    const run = frame_shaper.shape(word.text) catch return;
                    recordWordCaretStops(run, word.text.len, word_start, x, baseline);
                    drawText(context, run, x, baseline, allocator) catch return;
                    x += word.width;
                    if (index + 1 < line_words.len) {
                        const next_word = line_words[index + 1];
                        const gap_end = paragraph_start + sliceOffset(paragraph, next_word.text);
                        recordGapCaretStops(shown, word_start + word.text.len, gap_end, x, baseline, line.space_width);
                        x += line.space_width;
                    }
                }
                caret_x = x;
                caret_y = baseline;
                baseline -= line_height;
            }

            if (layout.words.len > 0) {
                const last_word = layout.words[layout.words.len - 1];
                const content_end = paragraph_start + sliceOffset(paragraph, last_word.text) + last_word.text.len;
                recordTrailingCaretStops(shown, content_end, paragraph_end, caret_x, caret_y, layout.natural_space_width);
            } else {
                recordTrailingCaretStops(shown, paragraph_start, paragraph_end, caret_x, caret_y, layout.natural_space_width);
            }
            baseline -= 10.5;
        } else {
            addCaretStop(paragraph_start, left, baseline);
            // Consecutive Returns create empty paragraphs. Give each one a
            // real visual row so its caret stop cannot collapse onto the
            // previous blank paragraph and confuse subsequent Backspace or
            // vertical-arrow movement.
            if (separator != null) baseline -= line_height + 10.5;
        }
        if (separator == null) break;
        addCaretStop(paragraph_end + 1, left, baseline);
        paragraph_start = paragraph_end + 1;
    }

    if (caretStopForOffset(app_state.cursor)) |position| {
        caret_x = position.x;
        caret_y = position.y;
    }
    app_state.caret_revision = app_state.document_revision;

    // The madder-red caret is the only chromatic accent on the sheet.
    CGContextSetRGBFillColor(context, 0.56, 0.17, 0.135, 0.9);
    // `caret_x` is the insertion boundary and therefore also the origin of the
    // following glyph. Keep the complete caret to its left so the accent never
    // paints over the character.
    const caret = Rect{ .origin = .{ .x = caret_x - 1.8, .y = caret_y - 4.0 }, .size = .{ .width = 1.15, .height = 21.5 } };
    CGContextFillRect(context, caret);
}

fn sliceOffset(container: []const u8, part: []const u8) usize {
    return @intFromPtr(part.ptr) - @intFromPtr(container.ptr);
}

fn addCaretStop(offset: usize, x: f64, y: f64) void {
    if (app_state.caret_stop_count > 0) {
        const previous = &app_state.caret_stops[app_state.caret_stop_count - 1];
        if (previous.offset == offset) {
            previous.* = .{ .offset = offset, .x = x, .y = y };
            return;
        }
    }
    if (app_state.caret_stop_count >= app_state.caret_stops.len) return;
    app_state.caret_stops[app_state.caret_stop_count] = .{ .offset = offset, .x = x, .y = y };
    app_state.caret_stop_count += 1;
}

fn recordWordCaretStops(run: shaping.Run, source_len: usize, source_start: usize, x: f64, y: f64) void {
    addCaretStop(source_start, x, y);
    var pen_x: f64 = 0;
    var previous_cluster: ?u32 = null;
    for (run.glyphs) |glyph| {
        if (previous_cluster == null or previous_cluster.? != glyph.cluster) {
            const cluster: usize = @intCast(glyph.cluster);
            if (cluster <= source_len)
                addCaretStop(source_start + cluster, x + pen_x, y);
            previous_cluster = glyph.cluster;
        }
        pen_x += glyph.x_advance;
    }
    addCaretStop(source_start + source_len, x + run.advance, y);
}

fn recordGapCaretStops(source: []const u8, start: usize, end: usize, x: f64, y: f64, width: f64) void {
    if (end <= start) return;
    var count: usize = 0;
    var cursor = start;
    while (cursor < end) : (count += 1) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(source[cursor]) catch 1;
        cursor = @min(end, cursor + @as(usize, @intCast(sequence_len)));
    }
    if (count == 0) return;

    addCaretStop(start, x, y);
    cursor = start;
    var index: usize = 0;
    while (cursor < end) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(source[cursor]) catch 1;
        cursor = @min(end, cursor + @as(usize, @intCast(sequence_len)));
        index += 1;
        addCaretStop(cursor, x + width * @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(count)), y);
    }
}

fn recordTrailingCaretStops(source: []const u8, start: usize, end: usize, initial_x: f64, y: f64, space_width: f64) void {
    if (end <= start) return;
    var x = initial_x;
    var cursor = start;
    addCaretStop(cursor, x, y);
    while (cursor < end) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(source[cursor]) catch 1;
        cursor = @min(end, cursor + @as(usize, @intCast(sequence_len)));
        x += space_width;
        addCaretStop(cursor, x, y);
    }
}

fn caretStopForOffset(offset: usize) ?CaretStop {
    var nearest: ?CaretStop = null;
    for (app_state.caret_stops[0..app_state.caret_stop_count]) |stop| {
        if (stop.offset == offset) return stop;
        if (stop.offset < offset and (nearest == null or stop.offset > nearest.?.offset)) nearest = stop;
    }
    return nearest;
}

fn acceptsFirstResponder(_: Obj, _: Sel) callconv(.c) i8 {
    return 1;
}

fn terminateAfterClose(_: Obj, _: Sel, _: Obj) callconv(.c) i8 {
    return 1;
}

fn keyDown(self: Obj, _: Sel, event: Obj) callconv(.c) void {
    const key_code = sendU16(event, "keyCode");
    const modifier_flags = sendU64(event, "modifierFlags");
    if (modifier_flags & (@as(u64, 1) << 20) != 0) {
        if (key_code == 12) sendVoidObj(send0(objc_getClass("NSApplication"), "sharedApplication"), "terminate:", null);
        return;
    }

    if (key_code == 123) {
        app_state.cursor = previousCaretBoundary(app_state.cursor);
        app_state.preferred_x_active = false;
    } else if (key_code == 124) {
        app_state.cursor = nextCaretBoundary(app_state.cursor);
        app_state.preferred_x_active = false;
    } else if (key_code == 126) {
        moveCursorVertically(true);
    } else if (key_code == 125) {
        moveCursorVertically(false);
    } else if (key_code == 51) {
        if (app_state.cursor > 0) deleteRange(previousCaretBoundary(app_state.cursor), app_state.cursor);
        app_state.preferred_x_active = false;
    } else if (key_code == 117) {
        if (app_state.cursor < app_state.typed_len) deleteRange(app_state.cursor, nextCaretBoundary(app_state.cursor));
        app_state.preferred_x_active = false;
    } else if (key_code == 36 or key_code == 76) {
        insertAtCursor("\n");
        app_state.preferred_x_active = false;
    } else {
        const characters = send0(event, "characters");
        const c_string = sendCString(characters, "UTF8String");
        if (c_string != null) {
            const bytes = std.mem.span(c_string.?);
            if (bytes.len > 0 and (bytes[0] >= 0x20 or bytes[0] == '\t')) insertAtCursor(bytes);
        }
        app_state.preferred_x_active = false;
    }
    sendVoidBool(self, "setNeedsDisplay:", 1);
}

fn previousCaretBoundary(position: usize) usize {
    if (app_state.caret_revision != app_state.document_revision)
        return previousCodepoint(position);

    var previous: ?usize = null;
    var found = false;
    for (app_state.caret_stops[0..app_state.caret_stop_count]) |stop| {
        if (stop.offset == position) found = true;
        if (stop.offset < position and (previous == null or stop.offset > previous.?))
            previous = stop.offset;
    }
    return if (found) previous orelse 0 else previousCodepoint(position);
}

fn nextCaretBoundary(position: usize) usize {
    if (app_state.caret_revision != app_state.document_revision)
        return nextCodepoint(position);

    var next: ?usize = null;
    var found = false;
    for (app_state.caret_stops[0..app_state.caret_stop_count]) |stop| {
        if (stop.offset == position) found = true;
        if (stop.offset > position and (next == null or stop.offset < next.?))
            next = stop.offset;
    }
    return if (found) next orelse app_state.typed_len else nextCodepoint(position);
}

fn previousCodepoint(position: usize) usize {
    if (position == 0) return 0;
    var result = position - 1;
    while (result > 0 and (app_state.typed[result] & 0xc0) == 0x80) result -= 1;
    return result;
}

fn nextCodepoint(position: usize) usize {
    if (position >= app_state.typed_len) return app_state.typed_len;
    const sequence_len = std.unicode.utf8ByteSequenceLength(app_state.typed[position]) catch 1;
    return @min(app_state.typed_len, position + @as(usize, @intCast(sequence_len)));
}

fn insertAtCursor(bytes: []const u8) void {
    if (bytes.len > app_state.typed.len - app_state.typed_len) return;
    const old_len = app_state.typed_len;
    const new_len = old_len + bytes.len;
    std.mem.copyBackwards(
        u8,
        app_state.typed[app_state.cursor + bytes.len .. new_len],
        app_state.typed[app_state.cursor..old_len],
    );
    @memcpy(app_state.typed[app_state.cursor .. app_state.cursor + bytes.len], bytes);
    app_state.cursor += bytes.len;
    app_state.typed_len = new_len;
    app_state.document_revision +%= 1;
}

fn deleteRange(start: usize, end: usize) void {
    if (start >= end or end > app_state.typed_len) return;
    const count = end - start;
    std.mem.copyForwards(
        u8,
        app_state.typed[start .. app_state.typed_len - count],
        app_state.typed[end..app_state.typed_len],
    );
    app_state.typed_len -= count;
    app_state.cursor = start;
    app_state.document_revision +%= 1;
}

fn moveCursorVertically(up: bool) void {
    const current = caretStopForOffset(app_state.cursor) orelse return;
    if (!app_state.preferred_x_active) {
        app_state.preferred_x = current.x;
        app_state.preferred_x_active = true;
    }

    var target_y: ?f64 = null;
    for (app_state.caret_stops[0..app_state.caret_stop_count]) |stop| {
        if (up) {
            if (stop.y <= current.y + 1.0) continue;
            if (target_y == null or stop.y < target_y.?) target_y = stop.y;
        } else {
            if (stop.y >= current.y - 1.0) continue;
            if (target_y == null or stop.y > target_y.?) target_y = stop.y;
        }
    }
    const row_y = target_y orelse return;

    var best: ?CaretStop = null;
    var best_distance = std.math.inf(f64);
    for (app_state.caret_stops[0..app_state.caret_stop_count]) |stop| {
        if (@abs(stop.y - row_y) > 0.5) continue;
        const distance = @abs(stop.x - app_state.preferred_x);
        if (distance < best_distance) {
            best = stop;
            best_distance = distance;
        }
    }
    if (best) |stop| app_state.cursor = stop.offset;
}

fn measureBodyText(context: ?*anyopaque, source: []const u8) f64 {
    const state = context orelse return 0;
    const shaper: *FrameShaper = @ptrCast(@alignCast(state));
    const run = shaper.shape(source) catch return 0;
    return run.advance;
}

fn drawText(context: Obj, run: shaping.Run, x: f64, y: f64, allocator: std.mem.Allocator) !void {
    if (run.glyphs.len == 0) return;
    const glyphs = try allocator.alloc(u16, run.glyphs.len);
    defer allocator.free(glyphs);
    const positions = try allocator.alloc(Point, run.glyphs.len);
    defer allocator.free(positions);

    var pen_x = x;
    var pen_y = y;
    for (run.glyphs, 0..) |glyph, index| {
        if (glyph.id > std.math.maxInt(u16)) return error.GlyphIdentifierTooLarge;
        glyphs[index] = @intCast(glyph.id);
        positions[index] = .{
            .x = pen_x + glyph.x_offset,
            .y = pen_y + glyph.y_offset,
        };
        pen_x += glyph.x_advance;
        pen_y += glyph.y_advance;
    }
    CTFontDrawGlyphs(app_state.body_font, glyphs.ptr, positions.ptr, glyphs.len, context);
}

fn makeString(comptime text: [:0]const u8) Obj {
    return makeStringSlice(text);
}

fn makeStringSlice(text: []const u8) Obj {
    if (text.len == 0) return CFStringCreateWithBytes(null, "".ptr, 0, utf8_encoding, 0);
    return CFStringCreateWithBytes(null, text.ptr, @intCast(text.len), utf8_encoding, 0);
}

fn selector(comptime name: [:0]const u8) Sel {
    return sel_registerName(name);
}

fn message(comptime Function: type) Function {
    return @ptrCast(&objc_msgSend);
}

fn send0(receiver: Obj, comptime name: [:0]const u8) Obj {
    return message(*const fn (Obj, Sel) callconv(.c) Obj)(receiver, selector(name));
}

fn sendVoid0(receiver: Obj, comptime name: [:0]const u8) void {
    message(*const fn (Obj, Sel) callconv(.c) void)(receiver, selector(name));
}

fn sendVoidObj(receiver: Obj, comptime name: [:0]const u8, value: Obj) void {
    message(*const fn (Obj, Sel, Obj) callconv(.c) void)(receiver, selector(name), value);
}

fn sendObj(receiver: Obj, comptime name: [:0]const u8, value: Obj) Obj {
    return message(*const fn (Obj, Sel, Obj) callconv(.c) Obj)(receiver, selector(name), value);
}

fn sendVoidBool(receiver: Obj, comptime name: [:0]const u8, value: i8) void {
    message(*const fn (Obj, Sel, i8) callconv(.c) void)(receiver, selector(name), value);
}

fn sendInteger(receiver: Obj, comptime name: [:0]const u8, value: isize) isize {
    return message(*const fn (Obj, Sel, isize) callconv(.c) isize)(receiver, selector(name), value);
}

fn sendRect(receiver: Obj, comptime name: [:0]const u8, rect: Rect) Obj {
    return message(*const fn (Obj, Sel, Rect) callconv(.c) Obj)(receiver, selector(name), rect);
}

fn sendRect0(receiver: Obj, comptime name: [:0]const u8) Rect {
    if (builtin.cpu.arch == .x86_64) {
        var result: Rect = undefined;
        const send_stret: *const fn (*Rect, Obj, Sel) callconv(.c) void = @ptrCast(&objc_msgSend_stret);
        send_stret(&result, receiver, selector(name));
        return result;
    }
    return message(*const fn (Obj, Sel) callconv(.c) Rect)(receiver, selector(name));
}

fn sendWindowInit(receiver: Obj, rect: Rect, style: u64, backing: u64, defer_flag: i8) Obj {
    return message(*const fn (Obj, Sel, Rect, u64, u64, i8) callconv(.c) Obj)(receiver, selector("initWithContentRect:styleMask:backing:defer:"), rect, style, backing, defer_flag);
}

fn sendU16(receiver: Obj, comptime name: [:0]const u8) u16 {
    return message(*const fn (Obj, Sel) callconv(.c) u16)(receiver, selector(name));
}

fn sendU64(receiver: Obj, comptime name: [:0]const u8) u64 {
    return message(*const fn (Obj, Sel) callconv(.c) u64)(receiver, selector(name));
}

fn sendMenuItemInit(receiver: Obj, title: Obj, action: Sel, key: Obj) Obj {
    return message(*const fn (Obj, Sel, Obj, Sel, Obj) callconv(.c) Obj)(
        receiver,
        selector("initWithTitle:action:keyEquivalent:"),
        title,
        action,
        key,
    );
}

fn sendCString(receiver: Obj, comptime name: [:0]const u8) ?[*:0]const u8 {
    return message(*const fn (Obj, Sel) callconv(.c) ?[*:0]const u8)(receiver, selector(name));
}
