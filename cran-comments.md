## Test environments

- Ubuntu 24.04, R 4.6 (local): `R CMD check --as-cran`, plus the
  suite under valgrind and under AddressSanitizer with
  UndefinedBehaviorSanitizer (tools/sanitize.sh).
- GitHub Actions: Ubuntu and macOS through r-ci, Windows through
  Rtools, and the r-hub clang-asan, gcc-asan and valgrind containers.
- win-builder: R-devel and R-release.

## R CMD check results

0 errors | 0 warnings | 2 notes

- New submission.
- "checking pragmas in C/C++ headers and code": src/civetweb.c and
  two Mbed TLS files carry pragmas that suppress compiler diagnostics.
  They are in the bundled upstream sources, unchanged apart from the
  patches in tools/patches/; the one pragma R treats as significant
  (-Wformat-nonliteral) was removed from CivetWeb by patch 0004.

## Spelling

"WebSocket" is the protocol's name (RFC 6455).

## Bundled code

CivetWeb (MIT) and Mbed TLS (Apache-2.0) are bundled under src/, with
every copyright holder named in Authors@R and in inst/COPYRIGHTS,
including the MD5 (Aladdin Enterprises, zlib-style licence) and the
public-domain SHA-1 implementations CivetWeb carries. The package's own
code is MIT.

## Examples

`serve()` and `run_server()` are in `\dontrun{}`: each runs an event
loop until interrupted. Every other example runs; the ones that start a
server bind port 0 on the loopback interface and stop it before
returning.

## Tests

The tests that open sockets run only when tinytest's `at_home()` is
TRUE, which CRAN's checks leave unset; the in-process tests run
everywhere.
