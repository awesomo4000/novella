# Vendored HarfBuzz

Novella vendors the complete upstream `src/` directory from HarfBuzz 14.2.1
and compiles the supported `harfbuzz.cc` single-translation-unit core. The
vendored sources are unmodified.

- Release: `14.2.1`
- Source: <https://github.com/harfbuzz/harfbuzz/releases/download/14.2.1/harfbuzz-14.2.1.tar.xz>
- Archive SHA-256: `a54a5d8e9380a41fbb762ce367bcbf7704792dfca0d93f1bbca86c5a57902e0e`
- License: MIT-style; see `COPYING`
- Vendored source size: 7,824 KiB including `COPYING` and this provenance file

Novella builds only the core OpenType shaper. The compile disables AAT,
bitmap, color, draw, paint, math, metadata, style, environment, and locale
support. It does not enable GLib, GObject, ICU, CoreText, DirectWrite,
FreeType, Graphite2, Cairo, or any HarfBuzz utility or subset library.

On macOS ReleaseSmall, the static HarfBuzz archive is 1,153,284 bytes and the
complete Novella executable is 3,546,440 bytes. `otool -L` reports only Apple
system frameworks and system runtimes; HarfBuzz is not a dynamic dependency.

