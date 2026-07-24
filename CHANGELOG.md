<!-- SPDX-License-Identifier: MPL-2.0 -->

# Changelog

## 07/24/2026

- Scoped the vendored XCB and Xau feature-test macros to Linux so the native
  macOS X11 build retains required Darwin socket and compatibility APIs.
- Added the X11 editing path with a dynamic UTF-8 gap-buffer document,
  HarfBuzz-cluster caret boundaries, insertion-point painting, horizontal and
  vertical arrows, Return, Backspace, and forward Delete.
- Vendored and statically linked libxkbcommon 1.13.2 plus the XCB XKB protocol
  binding for server-defined layouts, modifiers, UTF-8 text, dead keys,
  Compose sequences, and Ctrl-Q or Super-Q exit handling.

## 07/23/2026

- Extracted the X11 software surface, HarfBuzz run cache, FreeType glyph cache,
  and document painter into a platform-neutral software renderer.
- Connected the native Win32 application to the shared Junicode,
  HarfBuzz/justification, FreeType, and retained-sheet rendering path.
- Added flicker-resistant GDI DIB presentation with coalesced `WM_SIZE`
  invalidation and suppressed background erasure.
- Lowered the x86 and x86-64 Windows baseline to Windows 7 while keeping ARM64
  on Windows 10 or newer.
- Added Windows file, stdin, and literal UTF-8 startup text support.
- Scaled the Windows software page, typography, line metrics, and caret with
  system DPI so high-density displays preserve the intended logical layout.

## 07/22/2026

- Added the renderer-independent Knuth–Plass justification library.
- Added TeX badness, fitness, demerit, and line-layout tests.
- Added the native macOS CoreText writing-sheet sample with embedded Junicode.
- Added a pinned differential oracle against the original `justif/core`.
- Added visual cursor navigation, trailing-space advancement, and editing at
  the insertion point.
- Added a standard Command-Q menu action and `-f`, stdin, and `--text` input.
- Reduced the sheet's top surround while preserving its page-like margin.
- Replaced the raw embedded Junicode TTF with an XZ-compressed payload that is
  validated and decompressed in memory before CoreText use.
- Hardened whitespace-only trailing paragraphs and gave consecutive Returns
  distinct visual caret rows for predictable Backspace and arrow behavior.
- Removed the automatic demo passage so a no-argument launch starts with a
  blank writing sheet.
- Made each Return a single document and visual paragraph break so repeated
  Returns can be removed one at a time with Backspace.
- Removed the keyboard-instruction footer from the writing sheet.
- Added an isolated X11 sample target using statically linked vendored XCB and
  Xau core sources.
- Licensed original Novella source under MPL-2.0 while preserving all
  third-party terms.
- Added the major cross-platform application architecture specification.
- Added a Windows 10 native application target with an isolated Win32 window
  and per-monitor DPI support.
- Expanded the cross-platform architecture specification to define Windows as
  a third native shell alongside macOS and X11.
- Made shared HarfBuzz shaping and measurement authoritative for manuscript
  layout on macOS, X11, and Windows.
- Vendored HarfBuzz 14.2.1 and moved the macOS writing sheet from CoreText
  shaping to shared HarfBuzz glyph runs, measurements, and caret clusters.
- Positioned the macOS caret completely before its insertion boundary so it
  does not paint over the following character.
- Added justif-compatible badness-only emergency stretch and a real-font
  resize regression test to prevent catastrophic two-word spacing.
- Added zero-space wrap boundaries for oversized URLs and other uninterrupted
  tokens so editor text cannot escape the sheet horizontally.
- Made the rescue pass prefer contained ragged lines over overfull lines and
  bounded painted emergency spacing to prevent whitespace chasms.
- Added the retained raw-XCB software surface, shared sheet geometry, X11
  resize/expose/close lifecycle, and core `PutImage` presentation.
- Vendored a minimal static FreeType 2.14.3 rasterizer and connected the X11
  sheet to shared HarfBuzz shaping, Junicode, justification, startup text, and
  caret rendering.
- Coalesced queued X11 expose and resize events so each burst produces only one
  surface resize, layout, rasterization, and presentation.
- Cached HarfBuzz runs by UTF-8 content across X11 frames so resize-driven
  reflow reuses invariant word shaping and measurements.
- Cached normalized FreeType glyph coverage and bearings by glyph identifier
  so X11 repaints blend reusable bitmaps instead of rerasterizing every glyph.
- Replaced black resize clears with the native desktop color and requested
  northwest bit gravity so X11 servers preserve overlapping window contents.
