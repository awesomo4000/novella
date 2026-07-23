<!-- SPDX-License-Identifier: MPL-2.0 -->

# Spec 00: Cross-platform application architecture creation

**Status: proposed architecture. No implementation is authorized by this
document alone.**

Novella currently has a renderer-independent justification library, a native
AppKit/CoreText writing sheet, a minimal raw-XCB window target, and a minimal
native Win32 window target. The next major body of work is to reproduce the
macOS writing experience on X11 and Windows without introducing GTK, Qt,
Xlib, Cairo, WinUI, WPF, a browser runtime, or another widget toolkit.

The chosen architecture is a single custom-rendered editor with three thin
platform shells. XCB owns the X11 connection, window, events, and pixel
presentation. Win32 owns the Windows process, window, events, and native
presentation. Neither owns widgets, document state, editing semantics, or page
layout.

## Goals

- Preserve the quiet, paper-like macOS interface:
  - neutral desktop surround;
  - centered warm-white sheet;
  - restrained border and shadow;
  - small top writing margin;
  - Junicode body text;
  - madder-red insertion caret;
  - no sample text, automatic typing, toolbar, or instruction footer.
- Give macOS, X11, and Windows identical document and editing semantics.
- Shape and measure manuscript text once through shared HarfBuzz code so all
  three backends receive the same glyph identifiers, advances, clusters, and
  line-breaking inputs.
- Keep the justification library usable without any platform backend.
- Keep the X11 application independent of installed X11 client libraries.
- Statically link vendored X11-side dependencies.
- Use the X11 core protocol as the universal presentation fallback.
- Detect optional extensions at runtime and retain a core-protocol fallback.
- Keep the Windows application on native Win32 and system graphics/text APIs.
- Make novel-length editing, viewport scrolling, and paragraph reflow explicit
  architectural responsibilities rather than later platform hacks.
- Preserve the existing justif differential oracle.

## Non-goals

- Building a general-purpose widget toolkit.
- Recreating AppKit classes or APIs on X11 or Windows.
- Depending on GTK, Qt, Xlib, Xft, Cairo, Electron, or a browser DOM.
- Depending on WinUI, WPF, .NET, or a packaged application runtime.
- Using X core fonts for manuscript rendering.
- Pixel-identical glyph rasterization among the native macOS and Windows
  drawing paths and FreeType.
- Supporting every historical X11 visual in the first implementation.
- Implementing full XIM or Windows IME/preedit support in the first input
  milestone.
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

Commit `338f78a`, merged by `cb338f8`, adds the corresponding Windows
bootstrap:

- `src/platform/windows/main.zig`: Unicode Win32 application and message loop;
- `src/platform/windows/win32.zig`: isolated Windows header import;
- `src/platform/windows/novella.manifest`: Windows 10 compatibility and
  per-monitor-v2 DPI declaration with a per-monitor fallback;
- native `windows` and `run-windows` build steps.

The bootstrap creates, paints, resizes, and closes a native window. It proves
the Windows target, Unicode, DPI, and lifecycle boundary; it deliberately does
not yet import the shared editor or render the writing sheet.

## Architectural decision

Use a shared editor, HarfBuzz text engine, and sheet renderer above
platform-specific window, input, glyph-rasterization, and presentation
adapters:

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
              Shared Layout + HarfBuzz
               shaping + measurement
                           |
                           v
                    Shared Sheet
                  geometry + glyph runs
                           |
             +-------------+-------------+-------------+
             |                           |             |
             v                           v             v
        macOS canvas                 X11 canvas      Windows canvas
   CoreText/CoreGraphics              FreeType     DirectWrite/Direct2D
             |                     CPU pixel surface  |
             v                           |             v
          NSView                         v           HWND
                                   XCB presenter
```

Platform input code must never mutate document bytes directly. Platform
rendering code must never decide editing behavior. Shared editor code must not
import AppKit, CoreText, XCB, FreeType, xkbcommon, Win32, DirectWrite, or
Direct2D. HarfBuzz is isolated behind the shared text-engine module; document,
command, editor, and sheet modules do not call it directly.

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
    text_engine.zig    HarfBuzz shaping, measurement, clusters, glyph runs
    font_data.zig      Junicode decompression and validation

  platform/
    macos/
      main.zig
      appkit.zig       application, window, menu, native events
      coretext.zig     font face and positioned-glyph drawing
      canvas.zig       CoreGraphics canvas implementation

    x11/
      main.zig
      connection.zig   display parsing, connection, screen, errors
      window.zig       window creation, atoms, focus, resize, close
      input.zig        XKB/key events to normalized commands
      atoms.zig        ICCCM/EWMH atom ownership
      surface.zig      premultiplied client-side pixel buffer
      presenter.zig    core PutImage and optional SHM path
      freetype.zig     face loading and glyph rasterization

    windows/
      main.zig         process entry point and application lifetime
      win32.zig        narrow Windows API import boundary
      window.zig       class, HWND lifecycle, DPI, resize, close
      input.zig        messages to normalized commands and UTF-8
      directwrite.zig  memory font face and positioned-glyph drawing
      canvas.zig       Direct2D canvas and HWND presentation
      novella.manifest Windows compatibility and DPI metadata

build/
  macos.zig            AppKit/CoreText/CoreGraphics target wiring
  x11.zig              X11 target and static dependency wiring
  windows.zig          Win32/DirectWrite/Direct2D target wiring
  vendor.zig           vendored-library construction helpers

vendor/
  xcb/
  xau/
  freetype/            proposed, not yet vendored
  harfbuzz/            pinned shared OpenType shaper
  xkbcommon/           proposed, not yet vendored
```

The exact file split may be adjusted when a boundary proves too small to earn
its own module. The dependency direction may not be reversed.

## Responsibility map

| Responsibility | Shared | macOS | X11 | Windows |
|---|---|---|---|---|
| Document bytes and cursor | `Document`/`Editor` | — | — | — |
| Editing semantics | `Command` handling | Event translation | Event translation | Event translation |
| Paragraph justification | `Layout` | — | — | — |
| Sheet geometry and colors | `Sheet` | — | — | — |
| Scrolling and caret visibility | `Editor`/`Sheet` | — | — | — |
| Text shaping and measurement | HarfBuzz | — | — | — |
| Source clusters and caret stops | HarfBuzz + layout | — | — | — |
| Glyph rasterization | Interface | CoreText/CoreGraphics | FreeType | DirectWrite/Direct2D |
| Drawing primitives | Canvas contract | CoreGraphics | CPU surface | Direct2D |
| Window lifecycle | — | AppKit | XCB + ICCCM/EWMH | Win32 |
| Pixel presentation | — | `NSView` drawing | XCB PutImage/SHM | Direct2D HWND target |

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
does not affect any platform.

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
- requesting text metrics from the shared HarfBuzz text engine;
- invoking `justify.Layout`;
- creating zero-space wrap boundaries inside tokens wider than the available
  measure, preferring URL punctuation and otherwise preserving UTF-8
  boundaries;
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
drawGlyphRun(pre_shaped_run, origin, color)
endFrame()
```

The contract is conceptual. Zig compile-time composition is preferred over a
heap-allocated runtime vtable unless runtime backend switching becomes a real
requirement.

The CoreGraphics, software, and Direct2D implementations must blend the same
color values, consume the same sheet geometry, and draw the same pre-shaped
glyph identifiers at the same logical positions. Glyph pixels are allowed to
differ slightly because the platform rasterizers hint, antialias, and composite
independently.

## Text-engine contract

HarfBuzz is the single shaping and manuscript-measurement implementation for
macOS, X11, and Windows. Measuring raw Unicode strings in one path and asking a
platform text-layout API to shape them independently in another would disagree
eventually on ligatures, kerning, combining marks, complex scripts, or caret
clusters, and is prohibited for manuscript text.

HarfBuzz is an application-layer dependency, not a dependency of
`src/justify.zig`. The public renderer-independent justification API keeps its
measurement callback and can still be imported without HarfBuzz. The shared
Novella application supplies a HarfBuzz-backed callback through
`app/text_engine.zig`.

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
- immutable positioned glyph runs for the platform canvas;
- caret stops derived from clusters;
- stable behavior for the same font bytes, size, and scale.

The shared wrapper configures HarfBuzz explicitly and identically for every
target: OpenType font functions, face index, variation coordinates, size,
direction, script, language, cluster level, and feature set. Platform defaults
must not silently alter those inputs. HarfBuzz converts Unicode runs into
positioned glyphs and preserves cluster relationships to source text. Those
clusters are also the authoritative foundation for safe cursor movement and
later selection behavior.

Each backend receives that already-shaped run and may only rasterize and
present it:

- macOS maps the shared font to a `CTFont`/`CGFont` and draws explicit glyph
  identifiers and positions; it does not use `CTLine` to reshape the text;
- X11 loads those glyph identifiers through FreeType and blends their coverage
  into the software surface;
- Windows maps the shared font to an `IDWriteFontFace` and submits explicit
  glyph indices, advances, and offsets to the DirectWrite/Direct2D glyph-run
  drawing path; it does not use `IDWriteTextLayout` to reshape the text.

All justification widths come from HarfBuzz advances before rasterization.
Conversion from HarfBuzz font units to logical coordinates and any subpixel
rounding policy are shared and deterministic. A backend must not replace those
advances with hinted raster bounds.

## Shared font data

The compressed Junicode payload and its validation must move out of the macOS
backend into `app/font_data.zig`.

That module owns:

- the embedded XZ payload;
- expected decompressed length;
- XZ checksum enforcement;
- SFNT signature validation;
- allocator-owned decompressed bytes;
- HarfBuzz blob, face, and font creation from those bytes;
- an explicit lifetime suitable for HarfBuzz and every platform rasterizer.

The shared HarfBuzz face is authoritative for glyph identifiers and metrics.
The macOS backend creates its graphics font from the same bytes, the X11 backend
creates a FreeType memory face from them, and the Windows backend exposes them
to DirectWrite through a private in-memory font collection. These platform
faces exist only to rasterize the HarfBuzz-selected glyphs. No backend searches
the host for Junicode, and Fontconfig is not needed for the primary manuscript
face.

## X11 rendering architecture

XCB remains the only X11 transport. XCB drawing primitives are not used for
manuscript text.

The finished X11 rendering path is:

1. Receive the shared HarfBuzz glyph run and logical positions.
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

The macOS application remains native AppKit. CoreText/CoreGraphics remain the
font-face, glyph-rasterization, drawing, and presentation path, but HarfBuzz
replaces CoreText as the authority for manuscript shaping and measurement.

The macOS backend retains responsibility for:

- `NSApplication`, menus, window, and responder integration;
- Command-Q and normal application termination;
- conversion of AppKit events to shared commands;
- construction of the CoreText/CoreGraphics font face from shared bytes;
- drawing the explicit HarfBuzz glyph identifiers and positions;
- CoreGraphics drawing and presentation;
- device scale from the native window/screen.

It gives up responsibility for:

- document storage;
- cursor mutation;
- paragraph splitting;
- Return and deletion behavior;
- sheet geometry and visual constants;
- scroll policy;
- font decompression and validation;
- manuscript shaping, advances, clusters, and caret stops.

The macOS application is the behavioral reference during extraction. Each
shared-module move must preserve its visible result before the X11 and Windows
backends begin consuming that module.

## Windows backend after extraction

The Windows application remains a native Unicode Win32 program. Win32 is the
window and event boundary, not a second editor implementation. DirectWrite
provides the raster font face and explicit glyph-run drawing, while Direct2D
implements the canvas and presents into the `HWND`; these are operating-system
APIs rather than widget frameworks. HarfBuzz remains the text engine.

The Windows backend retains responsibility for:

- process entry, window-class registration, `HWND`, and message-loop lifetime;
- close, paint, size, focus, and per-monitor-DPI messages;
- conversion of Windows keyboard and text-input messages to shared commands;
- private DirectWrite font loading and drawing of positioned HarfBuzz glyphs;
- Direct2D drawing and device-resource recreation;
- conversion between logical units and the current window DPI.

It must turn client-size or DPI changes into shared `Resize` commands. It must
not use frame size as the editor viewport, and a `WM_DPICHANGED` transition must
update both the native window bounds and shared logical scale before repaint.

It gives up the same application responsibilities as the macOS backend:

- document storage and cursor mutation;
- paragraph splitting, Return, deletion, and navigation behavior;
- sheet geometry, visual constants, and scroll policy;
- font decompression and validation;
- manuscript shaping, advances, clusters, and caret stops.

The current `main.zig` may keep window creation and painting together while it
is only a bootstrap. Split `window.zig`, `input.zig`, `directwrite.zig`, and
`canvas.zig` when those responsibilities acquire real implementations; do not
create forwarding-only modules merely to match the proposed tree.

The application manifest remains part of the executable contract. The minimum
supported system is Windows 10 version 1607, the Win32 API is Unicode-only, and
per-monitor-v2 DPI behavior with a per-monitor fallback must remain declared or
be explicitly established before any window is created.

The minimum-version contract also governs in-memory font loading. The
Windows-10-Creators-Update `IDWriteInMemoryFontFileLoader` convenience API is
too new for version 1607. Use the older custom font-file and font-collection
loader interfaces available on the supported baseline, or explicitly raise the
minimum Windows version in a later specification.

## Dependency policy

### Existing

- libxcb 1.17.0: vendored core, static;
- libXau 1.0.12: vendored minimal MIT-MAGIC-COOKIE path, static;
- HarfBuzz 14.2.1: vendored minimal OpenType core, statically linked into the
  macOS application as the first shared-shaping integration;
- Zig standard-library XZ decompressor;
- macOS system frameworks only in the macOS target.
- Windows system APIs only in the Windows target; the bootstrap currently
  imports Win32 headers through Zig's MinGW-compatible libc environment.

### Proposed or not yet connected on every backend

- the existing pinned HarfBuzz configuration linked into the X11 and Windows
  application targets;
- FreeType: statically linked minimal TrueType/OpenType rasterization for X11;
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
FreeType dependencies without a concrete feature requirement. HarfBuzz
integrations such as GLib, ICU, CoreText, and DirectWrite remain disabled;
shared shaping uses the pinned built-in Unicode-data and OpenType configuration
so its behavior does not vary with the host platform.

On macOS, system calls, sockets, pthreads, and libc remain provided by dynamic
`libSystem`; Apple does not provide a fully static application runtime. The
requirement is that all non-system X11 client components are static.

On Windows, `USER32`, `KERNEL32`, DirectWrite, Direct2D, and other documented
Windows system components may be dynamic. No GTK, Qt, WinUI, WPF, .NET, or
third-party GUI runtime is introduced. The final dependency audit must list
both direct DLL imports and API-set imports. The current `@cImport` approach
requires libc headers and introduces Universal CRT imports; retain that choice
only if the convenience is worth the runtime surface, or replace the narrow
Win32 declarations with maintained Zig declarations before minimal dependency
closure is claimed.

## Build organization

The top-level build remains understandable by delegating platform construction
to build helpers.

Required user-facing steps:

```text
zig build test          shared library and editor tests only
zig build oracle        justif differential oracle
zig build               native executable on macOS or Windows
zig build run           native application on macOS or Windows
zig build windows       native or cross-targeted Windows executable
zig build run-windows   run the Windows executable on Windows
zig build x11           static-X11 executable
zig build run-x11       run the X11 executable using DISPLAY
```

Properties:

- shared tests do not compile AppKit, X11, or Win32 code;
- macOS framework links exist only in macOS target construction;
- Windows system-library links and the application manifest exist only in
  Windows target construction;
- X11 C libraries are built only when an X11 artifact needs them;
- the same pinned HarfBuzz configuration is built statically for macOS, X11,
  and Windows;
- the X11 module has no `/opt/X11`, Homebrew, or system X11 include/library
  path;
- `otool -L` on macOS shows no dynamic XCB/Xau/FreeType/HarfBuzz/xkbcommon;
- Windows PE import inspection records all system and Universal CRT imports and
  confirms that HarfBuzz is not a dynamic dependency;
- non-macOS targets do not instantiate the AppKit build graph, and non-Windows
  targets do not instantiate the Win32 build graph.

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
module and must not leak X atoms into the shared editor. The Windows adapter
uses the native Unicode clipboard and likewise keeps handles and clipboard
messages outside the shared editor.

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

- deterministic HarfBuzz glyph identifiers, advances, offsets, and clusters
  for pinned Junicode fixtures;
- identical HarfBuzz shaping fixtures on macOS, X11, and Windows targets;
- proof that the platform canvas receives the shared positioned run without
  reshaping or substituting advances;
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

### Windows integration tests

- cross-compile the supported x86-64 and ARM64 Windows targets;
- create, show, paint, resize, change DPI, and close a window on Windows;
- verify client-size and DPI messages produce normalized shared resize state;
- verify device-resource loss recreates the Direct2D target without losing the
  document;
- pass text, navigation, deletion, Return, and quit through the Win32 adapter;
- verify blank startup and native close behavior;
- inspect PE imports and record the intended Windows runtime dependencies;
- manually smoke-test at 100%, 150%, and mixed-monitor DPI scales.

Security-style path or sandbox tests, if added, must use dedicated disposable
paths under `/tmp/` and never target system or user files.

## Delivery phases

### `00-00` — shared editor extraction

- Introduce commands, document, and editor modules.
- Move all text mutation and cursor semantics out of AppKit callbacks.
- Preserve the macOS appearance and behavior.
- Keep the Win32 and X11 bootstrap lifecycle behavior stable.
- Add focused tests for the previously observed trailing-Return bug.

Exit gate: macOS behavior is unchanged, both bootstrap windows remain stable,
and shared tests own editing semantics.

### `00-01` — shared sheet and font-data extraction

- Move geometry, colors, viewport, and font decompression into shared modules.
- Introduce canvas and HarfBuzz text-engine contracts.
- Adapt CoreText/CoreGraphics to those contracts.
- Make the contracts available to both the X11 and Windows backends without
  importing either platform API into shared code.

Exit gate: macOS still renders the same blank sheet and manuscript without
platform-owned layout constants.

### `00-02` — platform surfaces and window lifecycle

- Split the sample into connection, window, surface, presenter, and atom
  modules.
- Split the Win32 bootstrap when window, input, and canvas responsibilities
  become substantive.
- Draw the paper and caret without text on X11 and Windows.
- Add X11 Expose, resize, `WM_DELETE_WINDOW`, and visual conversion.
- Add Win32 paint, client resize, per-monitor DPI, close, and Direct2D resource
  recreation.
- Keep core PutImage as the only required presenter.

Exit gate: repeated expose/resize/close cycles are stable on Xvfb, XQuartz, and
Windows, including a Windows DPI transition.

### `00-03` — shared shaping and platform glyph rasterizers

- Vendor pinned minimal HarfBuzz for all application targets and FreeType for
  X11.
- Load the shared Junicode bytes from memory.
- Shape and measure every manuscript run through the shared HarfBuzz module.
- Adapt macOS, X11, and Windows canvases to consume the exact shared glyph
  identifiers, advances, offsets, and clusters without reshaping.
- Rasterize, cache, blend, and present X11 glyph runs through FreeType.
- Load the same bytes through a private DirectWrite font collection.
- Connect the HarfBuzz measurement callback to `justify.Layout` for every
  application target.

Exit gate: X11 and Windows display justified Junicode paragraphs with correct
line and caret geometry, macOS remains visually stable, all three record the
same shaped-run fixtures, and X11 static-link and Windows PE-import audits pass.

### `00-04` — platform input parity

- Vendor and integrate minimal xkbcommon/XKB support.
- Translate X11 text, Compose, navigation, deletion, Return, and quit commands.
- Translate Win32 keyboard and Unicode text-input messages to the same command
  set without leaking virtual-key values into shared code.
- Track focus and keyboard-layout changes on both platforms.

Exit gate: the shared editor input suite passes through all three platform
adapters, and manual XQuartz and Windows typing match macOS semantics.

### `00-05` — novel-length viewport and performance

- Add dynamic document storage, paragraph caches, visible-run rasterization,
  and caret-following scroll.
- Measure reflow and rendering on long manuscripts on all three backends.
- Add dirty-rectangle and optional SHM presentation only after profiling.

Exit gate: sustained typing and navigation remain responsive on a realistic
novel-sized UTF-8 file without clipping the active caret.

### `00-06` — selection, clipboard, and hardening

- Specify and implement selection commands and visuals.
- Add X11 clipboard protocol plus native macOS and Windows clipboard
  integration.
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
- every application target shapes and measures manuscript text through the
  same pinned HarfBuzz implementation and configuration;
- platform canvases rasterize shared glyph runs without invoking a second text
  layout or shaping pass;
- macOS behavior remains stable through the extraction;
- Windows starts blank and reproduces the paper, Junicode text, justification,
  caret, Return, deletion, arrows, DPI-aware resize, scrolling, and clean close;
- X11 starts blank and reproduces the paper, Junicode text, justification,
  caret, Return, deletion, arrows, resize, scrolling, and clean close;
- Windows uses native Win32, DirectWrite, and Direct2D without a widget or
  managed runtime;
- X11 uses no GTK, Qt, Xlib, Xft, Cairo, or browser runtime;
- X11 has a tested core-protocol presentation path;
- all non-system X11 client dependencies are vendored and static;
- `zig build test`, `zig build oracle`, all three platform builds, integration
  tests, and dynamic-link audits pass;
- license and provenance documentation covers every vendored source and
  generated protocol file.

## Risks

- **Glyph pixels differ across platforms.** Shared HarfBuzz shaping makes glyph
  selection, advances, clusters, and line-breaking inputs deterministic, but
  CoreText/CoreGraphics, FreeType, and DirectWrite/Direct2D may hint and
  antialias outlines differently. Layout parity is required; pixel identity is
  not.
- **Shaping and caret boundaries are easy to split incorrectly.** Shaped source
  clusters, not raw code-point stepping, must be authoritative.
- **PutImage can be expensive over remote X.** Correct full-frame core
  presentation comes first; damage tracking and optional SHM follow profiling.
- **X11 visuals vary.** Native pixel conversion must inspect the server, and
  unsupported historical visuals must fail clearly until implemented.
- **Keyboard handling can grow into an input-method subsystem.** xkbcommon and
  Compose are in scope on X11, and Unicode Win32 messages are in scope on
  Windows; full XIM and Windows IME/preedit are separately specified.
- **Windows device and DPI state can change independently of document state.**
  Direct2D resources must be disposable and recreatable, while normalized
  resize and scale changes remain explicit shared commands.
- **Premature abstraction can obscure the small application.** Contracts stay
  narrow and are justified by three concrete backends.
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
- Microsoft, *Custom Font Collections (Windows 7/8)*:
  <https://learn.microsoft.com/windows/win32/directwrite/custom-font-collections>
- Microsoft, *Text Rendering with Direct2D and DirectWrite*:
  <https://learn.microsoft.com/windows/win32/direct2d/direct2d-and-directwrite>
- Microsoft, *Setting the default DPI awareness for a process*:
  <https://learn.microsoft.com/windows/win32/hidpi/setting-the-default-dpi-awareness-for-a-process>

## Estimate

This is a multi-phase XL body of work. Shared sheet geometry, HarfBuzz font
data, the raw-XCB retained surface/lifecycle, and the X11 FreeType rasterizer
have completed their initial integrations and dependency audits. X11 now
displays justified Junicode manuscript text through the core `PutImage` path
and coalesces queued expose and resize events before rendering each frame.

The shared editor/document extraction, XKB/xkbcommon input, and caret-command
parity remain before X11 is an interactive editor. Windows still needs the
shared HarfBuzz connection and its separate DirectWrite/Direct2D API and import
audit. Do not hide xkbcommon or Windows rendering work inside an unrelated
phase merely because the first X11 manuscript rendering now exists.
