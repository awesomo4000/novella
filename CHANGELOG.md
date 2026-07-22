<!-- SPDX-License-Identifier: MPL-2.0 -->

# Changelog

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
