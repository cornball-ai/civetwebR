# civetwebR 0.0.1.4

- CI (.github/workflows/ci.yaml): R CMD check on Linux and macOS through
  r-ci, failing on WARNINGs; Windows through r-lib/actions; and CRAN's
  additional checks in the r-hub containers, R built with clang's and
  gcc's AddressSanitizer and UndefinedBehaviorSanitizer and a valgrind
  instrumented R, failing on any sanitizer or memcheck report.
  `tools/sanitize.sh` is the local counterpart: the whole suite under
  valgrind, then under ASan and UBSan, with no test allowed to skip.
- man/ is committed, so a clone checks as the tarball does.
- civetweb suppressed `-Wformat-nonliteral` with pragmas, which
  `R CMD check --as-cran` reports as a WARNING; removed
  (tools/patches/0004). The remaining pragmas in civetweb and Mbed TLS
  suppress diagnostics R does not count as important and show as a NOTE.
- The static_dirs test read a body without a trailing newline through
  `readLines()`, which returns nothing for it on macOS; it reads by
  Content-Length now.

# civetwebR 0.0.1.3

- TLS. `start_server()` and `serve()` take `tls_cert`, a PEM file holding
  the certificate (and chain) followed by the private key; the port then
  speaks https and wss. Mbed TLS 3.6.7 is bundled in src/mbedtls/, fetched
  and sha256-verified by `tools/vendor-mbedtls.sh`, and compiled into the
  shared object, so nothing is needed from the system. `has_tls()` reports
  whether TLS was compiled in; a server handle carries `tls` and prints
  its scheme.
- The TLS paths of civetweb wrote to stderr; they now go through `mg_cry()`
  (tools/patches/0003). Mbed TLS's self tests are switched off in
  src/civetweb/civetwebr_mbedtls_config.h, so the shared object references
  neither printf() nor rand().
- DESCRIPTION lists the copyright holders of the bundled code, with the
  details in inst/COPYRIGHTS, and declares GNU make.

# civetwebR 0.0.1.2

- R CMD check is clean. civetweb's `sprintf()` calls go through
  `mg_snprintf()` (tools/patches/0001), `mg_cry()` no longer writes to
  stderr or log files (src/civetweb/external_mg_cry_internal_impl.inl;
  messages reach the context's `log_message` callback or are dropped),
  the `.inl` pieces live in src/civetweb/, the licence file is named as
  DESCRIPTION points to it, and .github is build-ignored.
- A request carrying both `Transfer-Encoding` and `Content-Length` is
  refused with 400 before it reaches R (tools/patches/0002; RFC 7230
  section 3.3.3). Upstream commit 588860e intends the same but does not
  compile, so the pin stays at its parent 3309a6c.
- `tools/vendor-civetweb.sh` re-fetches civetweb at the pinned commit,
  normalizes line endings and applies the patches; the commit is
  recorded in src/civetweb/COMMIT.

# civetwebR 0.0.1.1

- The C bridge keeps all state per server (`cw_server_t` behind an
  external pointer with a finalizer), so one R process can run several
  servers; `start_server(register = FALSE)` returns a handle without
  making it the default.
- WebSocket connects are routed through R before the handshake:
  `on_ws("connect")` sees the upgrade headers and peer address and can
  refuse with a status (403 by default). An accepted connection keeps
  the connect event's id until its close event.
- New lower-level driver: `next_event()`, `send_response()`,
  `ws_close()`, `server_port()`; `serve()` and `run_server()` are loops
  over it. `ws_send()` and `stop_server()` take a `server` argument.
- Every event carries `remote_addr` and `remote_port`; WebSocket frames
  carry `fin` and `binary`, and continuation frames are delivered.
- `static_dirs`: URL prefixes CivetWeb serves itself, with byte ranges,
  never reaching R. `ws_path` and `keep_alive` options; port 0 for an
  OS-chosen port.
- `stop_server()` answers pending requests with 503 and lets the workers
  write those answers before CivetWeb stops.
- Fixed: `Rf_error()` was called from CivetWeb worker threads on
  allocation failure; `ws_send()` could write to a connection being
  closed; `run_server()` errored on Ctrl-C instead of returning.
