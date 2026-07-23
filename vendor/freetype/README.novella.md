# Vendored FreeType

Novella vendors the complete FreeType 2.14.3 release archive and compiles a
minimal static rasterizer for the raw-X11 application.

- Release: `2.14.3`
- Source: <https://download.savannah.gnu.org/releases/freetype/freetype-2.14.3.tar.xz>
- Archive SHA-256: `36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f`
- License: FreeType License or GPLv2; see `LICENSE.TXT`, `docs/FTL.TXT`, and
  `docs/GPLv2.TXT`

The vendored upstream files are unmodified. Novella selects its build through
the custom configuration headers in `src/platform/x11/freetype_config`.
Only the base library, TrueType driver, SFNT support, PostScript glyph names,
and grayscale renderer are compiled. Compressed-font containers, embedded
bitmaps, color glyphs, SVG, variable-font handling, BDF metadata, PNG, Brotli,
zlib, bzip2, LZW, and FreeType-to-HarfBuzz integration are disabled. HarfBuzz
remains the independent authority for shaping and advances.

The complete vendored release occupies approximately 21 MiB. On macOS
ReleaseSmall, the selected static FreeType archive is 263,184 bytes and the
complete raw-X11 Novella executable is approximately 2.0 MiB. `otool -L`
reports only `libSystem`; FreeType is not a dynamic dependency.
