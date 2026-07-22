<!-- SPDX-License-Identifier: MPL-2.0 -->

# Third-party notices

## justif

The line-breaking arithmetic and total-fit design in `src/justify.zig` are a
Zig adaptation of the DOM-free core of `justif`, inspected at commit
`0ed7c3e388f94a277ebb27ddd39a680a32b6c191`.

- Project: <https://github.com/lyallcooper/justif>
- Copyright: 2026 Lyall Cooper
- License: MIT; see `LICENSES/justif-MIT.txt`

The optional differential oracle installs the published `justif` 0.4.2 package
under `oracle/node_modules`; `oracle/package-lock.json` pins its exact archive
and integrity hash. It is a development-only dependency and is not linked into
the Zig library or macOS application.

## Junicode

The macOS sample embeds an XZ-compressed copy of `Junicode-Roman.ttf`, the same
default face used by the `justif` demonstration. It is reconstructed in memory
before CoreText use; the font itself remains covered by the OFL.

- Project: <https://junicode.sourceforge.io/>
- Copyright: 2025 Peter S. Baker
- License: SIL Open Font License 1.1; see `LICENSES/OFL-Junicode.txt`

## XCB and Xau

The optional X11 sample statically compiles a minimal core subset of libxcb
1.17.0 and libXau 1.0.12 from `vendor/`. The XCB core protocol sources were
generated once from xcb-proto 1.17.0. No X11 client library is loaded at
runtime.

- Project: <https://www.x.org/wiki/Development/Documentation/XCB/>
- Releases: <https://www.x.org/releases/individual/xcb/>
- Licenses: MIT/X11-style; see `vendor/xcb/COPYING`,
  `vendor/xcb/COPYING.xcb-proto`, and `vendor/xau/COPYING`

## HarfBuzz

The macOS application statically compiles the HarfBuzz 14.2.1 OpenType shaping
core from `vendor/harfbuzz`. HarfBuzz supplies manuscript glyph selection,
positioning, clusters, and measurement; CoreText/CoreGraphics rasterize and
present the positioned glyphs.

- Project: <https://github.com/harfbuzz/harfbuzz>
- Release: <https://github.com/harfbuzz/harfbuzz/releases/tag/14.2.1>
- License: MIT-style; see `vendor/harfbuzz/COPYING`
- Provenance and build configuration: `vendor/harfbuzz/README.novella.md`

The files under `vendor/` are not covered by Novella's MPL-2.0 license. They
remain governed by their respective upstream terms. The Junicode font remains
under the SIL Open Font License. The adapted justification core preserves the
upstream justif MIT terms alongside MPL-2.0 for Novella's modifications.
References to upstream projects and contributors identify provenance and do
not imply endorsement of Novella.
