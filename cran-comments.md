## Resubmission

This is the third submission of a new package. The review of 0.1.1
asked that all authors, contributors and copyright holders of the
bundled code be in Authors@R, naming Daniel King and Adriaan de Jong.
What was done:

- Authors@R now names every individual a file header under src/
  credits as an author, not only the copyright holders it already
  named. Daniel King, Adriaan de Jong and Mathias Olsson are the
  Doxygen \author tags in Mbed TLS (ChaCha20/Poly1305, cipher and
  message-digest, PKCS#5); each is `ctb`, and the files carry Mbed
  TLS's own copyright line, which "The Mbed TLS Contributors" (`cph`)
  already covered. Simon Tatham wrote the accelerated SHA-512 in Mbed
  TLS's sha512.c for PuTTY under MIT and relicensed it Apache-2.0, so
  he is `ctb` and `cph`.
- Two CivetWeb copyright holders that its LICENSE.md names but its
  file headers do not, No Face Press, LLC (Thomas Davis) and F-Secure
  Corporation, are now `cph`.
- inst/civetweb/LICENSE.md, copied from CivetWeb, also carried the
  licences of optional components this package does not bundle (Lua,
  SQLite, Duktape, zlib) and so named their holders. It now holds
  only the CivetWeb section, which is what applies.
- inst/COPYRIGHTS lists the same people file by file, and records why
  the other names in the sources are not authors: Chris Hall is
  credited in sha1.inl for reporting a bug, and Rivest, Feistel,
  Rijmen and Bernstein are the designers of MD5, DES, AES and
  ChaCha20/Poly1305, not authors of this code.
- The comment on each person() names the files, so every entry can be
  matched to a header.

The first submission, 0.1.0 on 2026-10-13, drew a NOTE for pragmas
suppressing diagnostics in the bundled sources; 0.1.1 removed every
one of them (tools/patches/0007 and tools/patches/mbedtls/0001).

Since 0.1.1 the server also closes an HTTP connection with a FIN
instead of a reset (NEWS), hence the version bump to 0.1.2.

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

## Spelling

"WebSocket" is the protocol's name (RFC 6455).

## Bundled code

CivetWeb (MIT) and Mbed TLS (Apache-2.0) are bundled under src/, with
every copyright holder and every credited author named in Authors@R
and in inst/COPYRIGHTS, including the MD5 (Aladdin Enterprises,
zlib-style licence) and the public-domain SHA-1 implementations
CivetWeb carries. The package's own code is MIT.

## Examples

`serve()` and `run_server()` are in `\dontrun{}`: each runs an event
loop until interrupted. Every other example runs; the ones that start a
server bind port 0 on the loopback interface and stop it before
returning.

## Tests

The tests that open sockets run only when tinytest's `at_home()` is
TRUE, which CRAN's checks leave unset; the in-process tests run
everywhere.
