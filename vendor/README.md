# Vendored X11 components

The X11 sample compiles only the core protocol portion of XCB and the minimal
Xau authentication path. Both are linked statically; the build does not use
XQuartz or system X11 headers and libraries.

- libxcb 1.17.0 from `https://www.x.org/releases/individual/xcb/`
  - archive SHA-256: `599ebf9996710fea71622e6e184f3a8ad5b43d0e5fa8c4e407123c88a59a6d55`
- xcb-proto 1.17.0 from the same release directory
  - archive SHA-256: `2c1bacd2110f4799f74de6ebb714b94cf6f80fb112316b1219480fd22562148c`
  - used once to generate `xproto`, `bigreq`, and `xc_misc`; it is not a
    build-time or runtime dependency of this repository
- libXau 1.0.12 from `https://www.x.org/releases/individual/lib/`
  - archive SHA-256: `74d0e4dfa3d39ad8939e99bda37f5967aba528211076828464d2777d477fc0fb`

The vendored Xauth header and a few C sources have portability-only header
edits so this subset does not depend on the broader xorgproto header bundle.
The original license texts are preserved in each component directory.
