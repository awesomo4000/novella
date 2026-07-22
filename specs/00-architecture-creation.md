<!-- SPDX-License-Identifier: MPL-2.0 -->

# Spec 00: Cross-platform application architecture creation

**Status: proposed architecture. No implementation is authorized by this
document alone.**

Novella currently has a renderer-independent justification library, a native
AppKit/CoreText writing sheet, and a minimal raw-XCB window target. The next
major body of work is to reproduce the macOS writing experience on X11 without
introducing GTK, Qt, Xlib, Cairo, a browser runtime, or another widget toolkit.

The chosen architecture is a single custom-rendered editor with two thin
platform shells. XCB owns the X11 connection, window, events, and pixel
presentation. It does not own widgets, typography, document state, editing
semantics, or page layout.

## Goals

- Preserve the quiet, paper-like macOS interface:
  - neutral desktop surround;
  - centered warm-white sheet;
  - restrained border and shadow;
  - small top writing margin;
  - Junicode body text;
  - madder-red insertion caret;
  - no sample text, automatic typing, toolbar, or instruction footer.
- Give macOS and X11 identical document and editing semantics.
- Keep the justification library usable without either platform backend.
- Keep the X11 application independent of installed X11 client libraries.
- Statically link vendored X11-side dependencies.
- Use the X11 core protocol as the universal presentation fallback.
- Detect optional extensions at runtime and retain a core-protocol fallback.
- Make novel-length editing, viewport scrolling, and paragraph reflow explicit
  architectural responsibilities rather than later platform hacks.
- Preserve the existing justif differential oracle.

## Non-goals

- Building a general-purpose widget toolkit.
- Recreating AppKit classes or APIs on X11.
- Depending on GTK, Qt, Xlib, Xft, Cairo, Electron, or a browser DOM.
- Using X core fonts for manuscript rendering.
- Pixel-identical text rasterization between CoreText and FreeType.
- Supporting every historical X11 visual in the first implementation.
- Implementing full XIM/CJK input in the first input milestone.
- Adding menus, toolbars, document chrome, or visible keyboard instructions.
- Replacing the line-breaking algorithm or expanding its current feature set.

## Baseline

The baseline captured in commit `a8704f8` contains:

- `src/justify.zig`: renderer-independent line breaking;
- `src/platform/macos.zig`: the current combined editor, AppKit event bridge,
  CoreText metrics, and CoreGraphics renderer;
- `src/platform/x11.zig`: a minimal raw-XCB window and event loop;
- vendored, statically linked libxcb 1.17.0 and minimal libXau 1.0.12;
- an embedded XZ-compressed Junicode font;
- a 5/5 differential oracle against `justif` 0.4.2.

The X11 sample has been run successfully against XQuartz `:0`. Its
ReleaseSmall executable contains XCB and Xau and dynamically links only the
macOS system runtime. This proves the build and connection boundary, not the
editor architecture.

## Architectural decision

Use a shared editor and sheet renderer above platform-specific window, input,
text, and presentation adapters:

```text
Native event
    |
    v
Platform adapter -----> Command
                           |
                           v
                    Shared Editor
                           |
                   document mutation
                   layout invalidation
                   viewport adjustment
                           |
                           v
                    Shared Sheet
                   geometry + layout
                           |
             +-------------+-------------+
             |                           |
             v                           v
      macOS text/canvas            X11 text/canvas
      CoreText/CoreGraphics        HarfBuzz/FreeType
             |                     CPU pixel surface
             v                           |
          NSView                         v
                                   XCB presenter
```

Platform input code must never mutate document bytes directly. Platform
rendering code must never decide editing behavior. Shared editor code must not
import AppKit, CoreText, XCB, FreeType, HarfBuzz, or xkbcommon.

## Proposed source organization

```text
src/
  root.zig
  justify.zig

  app/
    commands.zig       normalized editing and lifecycle commands
    document.zig       UTF-8 storage, paragraphs, cursor boundaries
    editor.zig         command handling and editor state
    layout.zig         paragraph layout, caret rows, cache invalidation
    sheet.zig          shared page geometry, colors, and viewport
    canvas.zig         renderer-facing drawing contract
    text_engine.zig    shaping, measuring, and glyph-run contract
    font_data.zig      Junicode decompression and validation

  platform/
    macos/
      main.zig
      appkit.zig       application, window, menu, native events
      coretext.zig     shaping, measurement, cluster mapping
      canvas.zig       CoreGraphics implementation

    x11/
      main.zig
      connection.zig   display parsing, connection, screen, errors
      window.zig       window creation, atoms, focus, resize, close
      input.zig        XKB/key events to normalized commands
      atoms.zig        ICCCM/EWMH atom ownership
      surface.zig      premultiplied client-side pixel buffer
      presenter.zig    core PutImage and optional SHM path
      freetype.zig     face loading and glyph rasterization
      harfbuzz.zig     shaping and source-cluster mapping

build/
  macos.zig            AppKit/CoreText/CoreGraphics target wiring
  x11.zig              X11 target and static dependency wiring
  vendor.zig           vendored-library construction helpers

vendor/
  xcb/
  xau/
  freetype/            proposed, not yet vendored
  harfbuzz/            proposed, not yet vendored
  xkbcommon/           proposed, not yet vendored
```

The exact file split may be adjusted when a boundary proves too small to earn
its own module. The dependency direction may not be reversed.

## Responsibility map

| Responsibility | Shared | macOS | X11 |
|---|---|---|---|
| Document bytes and cursor | `Document`/`Editor` | — | — |
| Editing semantics | `Command` handling | Event translation | Event translation |
| Paragraph justification | `Layout` | — | — |
| Sheet geometry and colors | `Sheet` | — | — |
| Scrolling and caret visibility | `Editor`/`Sheet` | — | — |
| Text-engine contract | Interface | CoreText | HarfBuzz + FreeType |
| Glyph rasterization | Interface | CoreText | FreeType |
| Drawing primitives | Canvas contract | CoreGraphics | CPU surface |
| Window lifecycle | — | AppKit | XCB + ICCCM/EWMH |
| Pixel presentation | — | `NSView` drawing | XCB PutImage/SHM |

## Shared command model

Native events are normalized into a deliberately small command set. The
following is illustrative rather than an API lock:

```text
InsertUtf8(bytes)
InsertParagraph
DeleteBackward
DeleteForward
MoveLeft
MoveRight
MoveUp
MoveDown
MoveDocumentStart
MoveDocumentEnd
Resize(width, height, scale)
Redraw
Quit
```

Commands operate on logical text positions. Key codes and modifier masks do
not cross the platform boundary.

The first parity milestone must preserve these current behaviors:

- no-argument launch starts with an empty document;
- typing a space advances and displays the caret correctly;
- Return inserts exactly one paragraph separator;
- repeated trailing Returns create distinct visual rows;
- Backspace removes those Returns one at a time;
- Forward Delete edits after the caret;
- horizontal and vertical arrows move through visual caret stops;
- the native close action and platform quit command terminate cleanly.

## Document model

The fixed 64 KiB byte array in the current macOS backend must not become the
shared long-term representation.

The shared document owns:

- validated UTF-8 text;
- exactly one `\n` per paragraph boundary;
- a logical insertion position;
- paragraph boundary indexes;
- edit operations that preserve valid UTF-8;
- cursor movement boundaries derived from shaped clusters;
- revision identifiers for cache invalidation.

A gap buffer is sufficient for the first shared implementation. A piece table
or rope is deferred until measurement demonstrates that the gap buffer is a
problem. Storage must be hidden behind the document API so that transition
does not affect either platform.

Editing positions remain UTF-8 byte offsets at the justification boundary, but
user-visible cursor stops come from text clusters. A combining sequence or
ligature must not expose invalid intermediate caret positions merely because
it spans multiple code points or bytes.

## Paragraph layout and caching

`justify.Layout` remains the authoritative line breaker. The application layer
adds paragraph ownership and caching around it.

Each cached paragraph records at least:

- document revision and byte range;
- available measure width;
- font identity, size, and scale;
- measured words and chosen lines;
- shaped glyph runs for visible lines;
- caret stops mapped back to document byte offsets;
- total rendered height.

An edit invalidates the edited paragraph and any paragraph indexes shifted by
the edit. A width, font-size, or scale change invalidates affected line layout.
Scrolling alone must not re-run justification.

The shared layout layer is responsible for:

- splitting text into paragraphs;
- requesting text metrics from the active text engine;
- invoking `justify.Layout`;
- positioning lines and inter-word spaces;
- computing visual caret rows;
- reporting document-space bounds to the sheet viewport.

## Shared sheet

The page appearance is data, not platform policy. One shared sheet description
owns:

- surrounding desktop color;
- paper color;
- maximum paper width;
- outer and inner margins;
- top baseline inset;
- line height and paragraph gap;
- paper border color and width;
- shadow offset, blur, and opacity;
- manuscript ink color;
- caret color, width, height, and baseline offset;
- viewport and vertical scroll offset.

The sheet starts blank except for the caret. It draws no title, chapter label,
instruction footer, toolbar, status bar, or placeholder passage.

The shared sheet computes geometry in logical units. A platform scale converts
logical coordinates to device pixels. Geometry tests should record the
resulting drawing commands without invoking either native renderer.

## Canvas contract

The application does not need a widget hierarchy. A small canvas contract is
enough:

```text
beginFrame(width, height, scale)
clear(color)
fillRect(rect, color)
strokeRect(rect, width, color)
drawShadow(rect, offset, blur, color)
pushClip(rect)
popClip()
drawGlyphRun(run, origin, color)
endFrame()
```

The contract is conceptual. Zig compile-time composition is preferred over a
heap-allocated runtime vtable unless runtime backend switching becomes a real
requirement.

The CoreGraphics and software implementations must blend the same color values
and consume the same sheet geometry. Text rasterization is allowed to differ
slightly because CoreText and FreeType hint and rasterize independently.

## Text-engine contract

Measurement and drawing must consume the same shaping result. Measuring raw
Unicode strings in one path and independently drawing characters in another
will eventually disagree on ligatures, kerning, combining marks, or complex
scripts.

A shaped run conceptually contains:

- glyph identifiers;
- per-glyph advances and offsets;
- total advance;
- source-cluster byte offsets;
- ascent, descent, and leading;
- bounds needed for clipping and damage.

The text engine must provide:

- word/run measurement for `justify.Layout`;
- shaping with source clusters;
- glyph-run rendering through the platform canvas;
- caret stops derived from clusters;
- stable behavior for the same font bytes, size, and scale.

HarfBuzz is required before X11 text parity is declared complete. FreeType-only
character lookup plus kerning may be used as a bring-up step, but it is not the
finished text architecture.

HarfBuzz converts Unicode runs into positioned glyphs and preserves cluster
relationships to source text. Those clusters are also the correct foundation
for safe cursor movement and later selection behavior.

## Shared font data

The compressed Junicode payload and its validation must move out of the macOS
backend into `app/font_data.zig`.

That module owns:

- the embedded XZ payload;
- expected decompressed length;
- XZ checksum enforcement;
- SFNT signature validation;
- allocator-owned decompressed bytes;
- an explicit lifetime suitable for both CoreText and FreeType.

The macOS backend creates its graphics font from the shared bytes. The X11
backend creates a FreeType memory face from the same bytes. Neither backend
searches the host for Junicode, and Fontconfig is not needed for the primary
manuscript face.

## X11 rendering architecture

XCB remains the only X11 transport. XCB drawing primitives are not used for
manuscript text.

The finished X11 rendering path is:

1. Shape UTF-8 through HarfBuzz.
2. Load and rasterize shaped glyph identifiers through FreeType.
3. Receive grayscale glyph coverage bitmaps.
4. Blend coverage into a client-owned premultiplied RGBA surface.
5. Convert the surface to the selected X visual's native masks and byte order.
6. Present dirty rectangles through core `xcb_put_image`.
7. Use MIT-SHM only when detected and usable for the current connection.

FreeType's normal render mode supplies antialiased coverage bitmaps along with
baseline-relative glyph positioning. The application owns the blend into the
page surface.

### Surface and visual handling

The internal surface uses one documented pixel representation independent of
the X server. Presentation performs explicit conversion using setup and visual
metadata rather than assuming BGRA, 24-bit depth, or host byte order.

The first supported server visual is TrueColor at common 24/32-bit depths. An
unsupported visual must produce a clear startup error rather than corrupt
colors. Historical PseudoColor support is a later compatibility milestone and
requires explicit colormap policy.

### Damage and repaint

The X server is not the backing store. The client retains the complete current
surface and repaints after `Expose`.

Damage is accumulated and coalesced for:

- initial map and expose;
- window resize;
- text edit and reflow;
- caret movement or blink;
- viewport scroll;
- focus-state changes, if focus affects the caret.

The first correct implementation may present the whole window. Dirty-rectangle
presentation follows only after full-frame correctness is established.

Core PutImage is the compatibility path and works for local or remote X
connections. MIT-SHM is an optional local optimization and must never be
required to start or render.

## X11 window integration

`window.zig` owns all window-manager communication:

- `WM_PROTOCOLS` and `WM_DELETE_WINDOW`;
- `WM_NAME` plus `_NET_WM_NAME`/`UTF8_STRING`;
- `WM_CLASS`;
- appropriate normal-size hints;
- focus events;
- `ConfigureNotify` resize events;
- `Expose` repaint events;
- connection and asynchronous X error handling.

The event loop blocks on the XCB connection file descriptor when idle and
supports a timer deadline if caret blinking is added. It drains and coalesces
queued events before rendering a new frame.

The platform quit key becomes the shared `Quit` command. Window-manager close
also becomes `Quit`; it is not allowed to kill the connection as the normal
shutdown path.

## X11 keyboard input

Raw hardware key codes are not editing commands. The X11 input layer must
translate the server keymap and current modifier state.

The target stack is statically linked xkbcommon plus the minimal XKB protocol
integration needed to obtain and update the server keymap. This is a keyboard
library, not a widget toolkit.

The input layer owns:

- keymap and modifier state;
- UTF-8 production;
- Shift, Control, Alt, Super, and Caps Lock;
- layout-independent navigation keys;
- dead-key and Compose processing;
- keymap-change notification;
- filtering command shortcuts from inserted text.

Successful Compose sequences produce UTF-8 and enter the editor through
`InsertUtf8`. Navigation and deletion enter through their command variants.

The X11 dependency must have a basic fallback plan if the XKB extension is
unavailable. That fallback may support core key mapping and a deliberately
limited text subset, but the limitation must be reported. Full XIM/preedit and
CJK input remain a later specification because raw XCB has no direct equivalent
of AppKit's text-input services.

## macOS backend after extraction

The macOS application remains native AppKit. The refactor must not replace
CoreText or CoreGraphics merely to force identical platform internals.

The macOS backend retains responsibility for:

- `NSApplication`, menus, window, and responder integration;
- Command-Q and normal application termination;
- conversion of AppKit events to shared commands;
- CoreText shaping and metrics;
- CoreGraphics drawing;
- device scale from the native window/screen.

It gives up responsibility for:

- document storage;
- cursor mutation;
- paragraph splitting;
- Return and deletion behavior;
- sheet geometry and visual constants;
- scroll policy;
- font decompression and validation.

The macOS application is the behavioral reference during extraction. Each
shared-module move must preserve its visible result before the X11 backend
begins consuming that module.

## Dependency policy

### Existing

- libxcb 1.17.0: vendored core, static;
- libXau 1.0.12: vendored minimal MIT-MAGIC-COOKIE path, static;
- Zig standard-library XZ decompressor;
- macOS system frameworks only in the macOS target.

### Proposed

- FreeType: statically linked minimal TrueType/OpenType configuration;
- HarfBuzz: statically linked minimal shaping configuration;
- xkbcommon: statically linked keyboard and Compose support;
- generated core files for the XKB and optional SHM XCB extensions as needed.

Proposed dependencies are not approved merely by appearing in this spec. Each
vendoring change must record:

- exact upstream version and source URL;
- archive checksum or immutable commit;
- complete license text and notices;
- generated-file provenance;
- local portability patches;
- enabled and disabled features;
- resulting static and executable sizes;
- dynamic-link audit proving no accidental system X11 dependency.

Do not add Fontconfig for the embedded manuscript face. Do not enable optional
FreeType/HarfBuzz dependencies without a concrete feature requirement.

On macOS, system calls, sockets, pthreads, and libc remain provided by dynamic
`libSystem`; Apple does not provide a fully static application runtime. The
requirement is that all non-system X11 client components are static.

## Build organization

The top-level build remains understandable by delegating platform construction
to build helpers.

Required user-facing steps:

```text
zig build test          shared library and editor tests only
zig build oracle        justif differential oracle
zig build               native macOS executable on macOS
zig build run           native macOS application on macOS
zig build x11           static-X11 executable
zig build run-x11       run the X11 executable using DISPLAY
```

Properties:

- shared tests do not compile AppKit or X11 code;
- macOS framework links exist only in macOS target construction;
- X11 C libraries are built only when an X11 artifact needs them;
- the X11 module has no `/opt/X11`, Homebrew, or system X11 include/library
  path;
- `otool -L` on macOS shows no dynamic XCB/Xau/FreeType/HarfBuzz/xkbcommon;
- non-macOS X11 cross-targets do not instantiate the AppKit build graph.

The `specs/` directory is repository design material and does not need to be
included in the downstream Zig package unless a later packaging decision says
otherwise.

## Viewport and novel-length behavior

The current application clips content after it reaches the bottom of the
sheet. That is not sufficient for typing a novel.

The shared editor must maintain a vertical viewport such that:

- the caret is always visible after insertion, deletion, or movement;
- upward movement can reveal earlier content;
- a resize retains the logical caret and chooses the smallest scroll change
  needed to reveal it;
- layout positions are in document space and translated by the viewport;
- the paper remains visually continuous rather than becoming a stack of UI
  cards;
- paragraphs outside the viewport do not require glyph rasterization.

Scrollbar chrome is not required. Mouse wheel, trackpad, Page Up/Page Down,
and direct scroll commands can be specified after keyboard parity.

## Clipboard and selection

Clipboard is deliberately after the first editor-parity milestone.

The eventual X11 implementation must handle `CLIPBOARD`, preferably `PRIMARY`,
`TARGETS`, `UTF8_STRING`, selection ownership, conversion requests, and INCR
transfers for large selections. This belongs in an isolated `selection.zig`
module and must not leak X atoms into the shared editor.

The shared editor will eventually own a logical selection range and commands
such as copy, cut, paste, extend-left, and extend-right. No selection UI is
added until shaped-cluster caret positions are correct.

## Compatibility strategy

"Runs on all X servers" means the client uses standardized core protocol for
its required window and presentation operations. It does not mean one binary
runs on every operating system or CPU.

Compatibility tiers:

1. **Required core path**
   - standard X connection and authentication;
   - core window/events/properties;
   - TrueColor visual;
   - core PutImage;
   - client-side text and page rendering.
2. **Optional acceleration and input**
   - MIT-SHM for local presentation;
   - XKB for complete keymap integration.
3. **Later compatibility**
   - PseudoColor visuals;
   - full XIM/preedit;
   - uncommon authentication mechanisms beyond current Xau support.

Every optional extension is queried before use. Absence either selects a
documented fallback or produces an explicit unsupported-feature error; it must
not crash or hang.

## Testing strategy

### Shared unit tests

- UTF-8 insertion and deletion;
- paragraph splitting and joining;
- repeated trailing Returns and one-at-a-time Backspace;
- forward deletion around paragraph boundaries;
- horizontal and vertical movement;
- shaped-cluster caret boundaries;
- command normalization independent of platform key codes;
- caret visibility and viewport adjustment;
- paragraph cache invalidation;
- resize-driven reflow;
- blank startup.

### Justification tests

- preserve all existing arithmetic and layout tests;
- preserve 5/5 justif oracle agreement;
- add paragraph-cache tests without changing the algorithm's results.

### Sheet and software-renderer tests

- record deterministic shared drawing commands for known viewport sizes;
- test paper and margin geometry numerically;
- test clipping and scroll translation;
- test premultiplied alpha blending;
- test glyph-mask blending using a fixed synthetic mask;
- test native visual conversion and byte order;
- use golden images only where pinned font/rasterizer versions make them
  deterministic.

### X11 integration tests

- connect, create, name, map, expose, resize, and close under Xvfb;
- exercise the core PutImage path even when SHM is available;
- exercise the SHM path separately when supported;
- inject or synthesize focused key events only in a dedicated test server;
- verify the window survives expose/resize cycles;
- verify connection failure reports a useful error;
- manually smoke-test XQuartz and at least one Linux X server;
- audit final dynamic dependencies.

Security-style path or sandbox tests, if added, must use dedicated disposable
paths under `/tmp/` and never target system or user files.

## Delivery phases

### `00-00` — shared editor extraction

- Introduce commands, document, and editor modules.
- Move all text mutation and cursor semantics out of AppKit callbacks.
- Preserve the macOS appearance and behavior.
- Add focused tests for the previously observed trailing-Return bug.

Exit gate: macOS behavior unchanged; shared tests own editing semantics.

### `00-01` — shared sheet and font-data extraction

- Move geometry, colors, viewport, and font decompression into shared modules.
- Introduce canvas and text-engine contracts.
- Adapt CoreText/CoreGraphics to those contracts.

Exit gate: macOS still renders the same blank sheet and manuscript without
platform-owned layout constants.

### `00-02` — X11 software surface and window lifecycle

- Split the sample into connection, window, surface, presenter, and atom
  modules.
- Draw the paper and caret without text.
- Add Expose, resize, `WM_DELETE_WINDOW`, and visual conversion.
- Keep core PutImage as the only required presenter.

Exit gate: repeated expose/resize/close cycles are stable on Xvfb and XQuartz.

### `00-03` — FreeType and HarfBuzz text

- Vendor pinned minimal FreeType and HarfBuzz sources.
- Load the shared Junicode bytes from memory.
- Shape, measure, rasterize, cache, blend, and present glyph runs.
- Connect X11 measurement to `justify.Layout`.

Exit gate: X11 displays justified Junicode paragraphs with correct line and
caret geometry; static-link audit passes.

### `00-04` — X11 input parity

- Vendor and integrate minimal xkbcommon/XKB support.
- Translate text, Compose, navigation, deletion, Return, and quit commands.
- Track focus and keymap changes.

Exit gate: the shared editor input suite passes through both platform adapters,
and manual XQuartz typing matches macOS semantics.

### `00-05` — novel-length viewport and performance

- Add dynamic document storage, paragraph caches, visible-run rasterization,
  and caret-following scroll.
- Measure reflow and rendering on long manuscripts.
- Add dirty-rectangle and optional SHM presentation only after profiling.

Exit gate: sustained typing and navigation remain responsive on a realistic
novel-sized UTF-8 file without clipping the active caret.

### `00-06` — selection, clipboard, and hardening

- Specify and implement selection commands and visuals.
- Add X11 clipboard protocol and native macOS clipboard integration.
- Expand server, visual, keyboard-layout, and failure-mode coverage.

Exit gate: cross-platform copy/paste and selection are correct, and every
optional X11 feature has a tested fallback or clear error.

Each phase should become its own implementation spec before code begins. A
phase may be split further if its dependency or testing work is too large for
one reviewable change.

## Acceptance criteria for the major architecture

The architecture is complete when:

- `src/justify.zig` and shared editor tests compile without platform libraries;
- no platform event handler mutates document bytes directly;
- no platform renderer owns sheet layout constants;
- macOS behavior remains stable through the extraction;
- X11 starts blank and reproduces the paper, Junicode text, justification,
  caret, Return, deletion, arrows, resize, scrolling, and clean close;
- X11 uses no GTK, Qt, Xlib, Xft, Cairo, or browser runtime;
- X11 has a tested core-protocol presentation path;
- all non-system X11 client dependencies are vendored and static;
- `zig build test`, `zig build oracle`, both platform builds, integration
  tests, and dynamic-link audits pass;
- license and provenance documentation covers every vendored source and
  generated protocol file.

## Risks

- **Text metrics differ across platforms.** Shared font bytes and dimensions
  limit divergence, but CoreText and FreeType may choose different hinting.
  Behavioral parity is required; pixel identity is not.
- **Shaping and caret boundaries are easy to split incorrectly.** Shaped source
  clusters, not raw code-point stepping, must be authoritative.
- **PutImage can be expensive over remote X.** Correct full-frame core
  presentation comes first; damage tracking and optional SHM follow profiling.
- **X11 visuals vary.** Native pixel conversion must inspect the server, and
  unsupported historical visuals must fail clearly until implemented.
- **Keyboard handling can grow into an input-method subsystem.** xkbcommon and
  Compose are in scope; full XIM is separately specified.
- **Premature abstraction can obscure the small application.** Contracts stay
  narrow and are justified by two concrete backends.
- **Vendored libraries can dominate source and binary size.** Minimal feature
  configurations and link audits are mandatory for each addition.

## References

- X.Org, *Basic Graphics Programming With The XCB Library*:
  <https://www.x.org/archive/X11R7.5/doc/libxcb/tutorial/index.html>
- X.Org, *X Window System Protocol*:
  <https://www.x.org/releases/current/doc/xproto/x11protocol.pdf>
- FreeType tutorial:
  <https://freetype.org/freetype2/docs/tutorial/step1.html>
- HarfBuzz shaping API:
  <https://harfbuzz.github.io/harfbuzz-hb-shape.html>
- HarfBuzz buffer and cluster API:
  <https://harfbuzz.github.io/harfbuzz-hb-buffer.html>
- xkbcommon Compose support:
  <https://xkbcommon.org/doc/current/group__compose.html>

## Estimate

This is a multi-phase XL body of work. `00-00` and `00-01` should be completed
before any attempt to make the X11 sample render manuscript text. FreeType,
HarfBuzz, and xkbcommon vendoring each require their own dependency audit and
should not be hidden inside an otherwise unrelated phase.
