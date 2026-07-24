# Vendored components

## HarfBuzz

Novella compiles a pinned minimal HarfBuzz core statically for deterministic
manuscript shaping and measurement. See `harfbuzz/README.novella.md` for its
version, checksum, build configuration, sizes, and license.

## X11

The X11 sample compiles only the core protocol portion of XCB and the minimal
Xau authentication path. Both are linked statically; the build does not use
XQuartz or system X11 headers and libraries.

- libxcb 1.17.0 from `https://www.x.org/releases/individual/xcb/`
  - archive SHA-256: `599ebf9996710fea71622e6e184f3a8ad5b43d0e5fa8c4e407123c88a59a6d55`
- xcb-proto 1.17.0 from the same release directory
  - archive SHA-256: `2c1bacd2110f4799f74de6ebb714b94cf6f80fb112316b1219480fd22562148c`
  - used once to generate `xproto`, `bigreq`, and `xc_misc`; it is not a
    build-time or runtime dependency of this repository
  - its `xkb.xml` is also used once with libxcb 1.17.0 `c_client.py` to
    generate the checked-in `xkb.c` and `xkb.h` protocol binding
- libXau 1.0.12 from `https://www.x.org/releases/individual/lib/`
  - archive SHA-256: `74d0e4dfa3d39ad8939e99bda37f5967aba528211076828464d2777d477fc0fb`

The vendored Xauth header and a few C sources have portability-only header
edits so this subset does not depend on the broader xorgproto header bundle.
The original license texts are preserved in each component directory.

## Keyboard input

The X11 application statically links libxkbcommon 1.13.2 and its X11 adapter
to interpret each server keyboard map, modifiers, UTF-8 text, dead keys, and
Compose sequences. See `xkbcommon/README.novella.md` for the immutable source
revision, checksum, parser generation, configuration, and license.
