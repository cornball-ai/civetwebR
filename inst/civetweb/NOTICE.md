## CivetWeb vendored source

`src/civetweb.c`, `src/civetweb.h` and `src/civetweb/*.inl` (except the
`external_*.inl` hooks, which are this package's own) are CivetWeb,
https://github.com/civetweb/civetweb/, at the commit recorded in
`src/civetweb/COMMIT`, fetched by `tools/vendor-civetweb.sh`.

The patches in `tools/patches/` are applied to that commit; each one's
header says what it changes and why. Copyright and licence notices for
everything bundled are in `inst/COPYRIGHTS`, and the applicable section
of CivetWeb's LICENSE.md is `inst/civetweb/LICENSE.md`.
