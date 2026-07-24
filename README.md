<!-- SPDX-License-Identifier: MPL-2.0 -->

# novella

`novella` is a DOM-free Zig 0.16 library for publication-style paragraph
justification, accompanied by native macOS, Win32, and raw-X11 writing sheets. Its
whole-paragraph line breaker is derived from the TeX-style core in
[`justif`](https://github.com/lyallcooper/justif): every feasible sequence of
breaks is considered, and adjacent line fitness participates in the result.

The library is renderer-independent. Supply a text measurement callback and a
measure; `Layout.init` returns word ranges plus the exact space width for every
line:

```zig
var layout = try novella.Layout.init(
    allocator,
    paragraph,
    420.0,
    .{ .context = font, .measure_fn = measureWithYourRenderer },
    .{},
);
defer layout.deinit(allocator);

for (layout.lines) |line| {
    // Draw layout.words[line.word_start..line.word_end], advancing by
    // line.space_width between words.
}
```

The paragraph text must remain alive while `layout.words` is being used.
`Layout` owns only its word and line arrays.

## Build and run

The library tests are platform-independent:

```sh
zig build test
```

The sample uses macOS system frameworks plus a statically compiled, vendored
HarfBuzz core. It embeds an XZ-compressed Junicode payload, inflating and
checksum-validating it in memory before HarfBuzz and CoreText load the same
bytes. It therefore has no runtime files or installed package dependencies:

```sh
zig build run
```

With no arguments, the app opens a blank writing sheet. The arrow keys move the
insertion point, Backspace and Forward Delete edit around it, Return starts a
paragraph, and Command-Q quits. Paragraphs reflow as the manuscript grows.
HarfBuzz is authoritative for glyph selection, advances, clusters, caret
boundaries, and the measurements passed to the justification algorithm;
CoreText draws those pre-shaped glyphs without reshaping the text.

Start with your own UTF-8 text from a file, stdin, or a literal argument:

```sh
zig build run -- -f manuscript.txt
zig build run -- - < manuscript.txt
zig build run -- --text "The first sentence was already waiting."
```

### Windows platform sample

On Windows, the default build installs a native Unicode GUI application that
displays the same justified Junicode sheet as X11. HarfBuzz shaping, FreeType
glyph caching, sheet painting, and the retained software surface are shared
with X11; Win32 owns only the native window, message loop, and GDI DIB
presentation. Background erasure is suppressed so resize and expose repaint
completed retained frames without a white intermediate clear.

x86 and x86-64 builds target Windows 7 or newer. Windows 7 installations need
Microsoft's Universal CRT update, which supplies the API-set DLLs imported by
Zig's C/C++ runtime. ARM64 builds require Windows 10 or newer:

```sh
zig build
zig build run
zig build run -- --text "The first sentence was already waiting."
```

The explicit platform steps are `zig build windows` and
`zig build run-windows`. Initial UTF-8 text accepts the same `-f`, stdin, and
`--text` forms as X11. The Windows and X11 sheets are currently display-only;
interactive native input follows the shared editor extraction.

### X11 platform sample

The X11 target is deliberately separate from the AppKit application. It uses
only raw XCB transport: a retained client-side pixel surface is presented with
core `PutImage`. Vendored HarfBuzz shapes the embedded Junicode face and a
minimal vendored FreeType rasterizer blends the selected glyph masks. XCB,
Xau, HarfBuzz, and FreeType are static, without installed X11 headers, Xft,
Fontconfig, or host fonts. Set `DISPLAY` to an active server and build or run
it with:

```sh
zig build x11
DISPLAY=:0 zig build run-x11
DISPLAY=:0 zig build run-x11 -- --text "The first sentence was already waiting."
DISPLAY=:0 zig build run-x11 -- -f manuscript.txt
```

With no arguments it opens a blank sheet. Initial UTF-8 text can come from a
literal, file, or stdin and is justified through the same HarfBuzz measurements
and line breaker as macOS. Expose, resize, and window-manager close are handled;
interactive XKB text entry and editing are the next X11 milestone. On macOS,
`otool -L` reports only `libSystem` for the X11 executable.

## Differential oracle

The unit tests cover arithmetic and API invariants. A separate differential
oracle runs identical mock-font paragraphs through this Zig library and the
published `justif/core` implementation, then compares line text, adjustment
ratios, and total demerits:

```sh
npm install --prefix oracle
zig build oracle
```

The dependency is locked to `justif` 0.4.2 in `oracle/package-lock.json`.
Oracle cases deliberately cover the shared plain-text feature set. They do not
claim parity for features this extraction does not yet implement, such as
hyphenation, character protrusion, CJK breaking, tracking, or variable-font
expansion.

## Scope

This extraction covers the reusable heart of `justif`: TeX-exact
badness, fitness classes, demerits, whole-paragraph optimal breaking, flexible
word spaces, a natural final line, an emergency-stretch pass, and editor-safe
wrapping of oversized tokens without inserted spaces. DOM-only
features such as CSS run reconstruction are intentionally outside this Zig
library. Hyphenation patterns and variable-font expansion are also left as
future renderer-facing extensions.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for source and font
attribution.

## License

Original Novella code is licensed under the [Mozilla Public License
2.0](LICENSE). When MPL-covered Novella files are distributed with
modifications, those files and their modifications must remain available under
MPL-2.0. Separate applications and source files that merely import, link to, or
use Novella may remain proprietary or use another license.

Third-party files under `vendor/` and the Junicode font payload retain their
upstream licenses. The adapted justification core preserves the upstream
justif MIT terms alongside MPL-2.0 for Novella's modifications. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for details.
