# Vendored libxkbcommon

Novella vendors libxkbcommon 1.13.2 from the immutable upstream tag archive:

- source: `https://github.com/xkbcommon/libxkbcommon/archive/refs/tags/xkbcommon-1.13.2.tar.gz`
- tag commit: `d1442aaa6b635551182e83c3b55037f4c118c962`
- archive SHA-256: `acc4d5f7c3cbba5f9f8d08d8bdbeede84ecede46792f47929aa9321873385528`

Only `src`, `include`, and the upstream `LICENSE` are retained. Novella builds
the core and X11 adapter as static libraries. It does not use a system
libxkbcommon at build time or runtime.

Upstream requires Bison 3.6 or newer and intentionally does not carry a
pre-generated XKB parser. The checked-in `src/xkbcomp/parser.c` and
`src/xkbcomp/parser.h` were generated once with GNU Bison 3.8.2:

```text
bison --defines=parser.h -o parser.c -p _xkbcommon_ src/xkbcomp/parser.y
```

The generated parser is compiled normally; Bison is not a Novella build-time
or runtime dependency.
