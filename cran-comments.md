## Test environments

- Ubuntu 24.04, R 4.6 (local): `R CMD check --as-cran`, plus the
  suite under valgrind and under AddressSanitizer with
  UndefinedBehaviorSanitizer (tools/sanitize.sh).
- GitHub Actions: Ubuntu and macOS through r-ci, Windows through
  Rtools, and the r-hub clang-asan, gcc-asan and valgrind containers.
- win-builder: R-devel and R-release.

## R CMD check results

0 errors | 0 warnings | 1 note

- New submission.

The first submission, 0.1.0 on 2026-10-13, drew a NOTE for pragmas
suppressing diagnostics in the bundled CivetWeb and Mbed TLS sources.
0.1.1 removes every one of them (tools/patches/0007 and
tools/patches/mbedtls/0001). What they hid is five static helpers
CivetWeb does not use in this configuration, which gcc -Wall reports
as defined but not used.

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
