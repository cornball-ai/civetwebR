# civetwebR 0.1.3

- Request framing is checked where upstream CivetWeb leaves it open.
  A request with more than 64 headers is refused with 400; civetweb
  accepted it and dropped the extra headers, a Content-Length or
  Transfer-Encoding among them included (upstream issue #1446, PR
  #1448). A chunk size past INT64_MAX is a protocol error, answered
  with 400 before R sees the request; it made content_len negative,
  and mg_read() then returned the rest of the stream as a body of
  unknown length (upstream PR #1449). A failed realloc at start no
  longer frees the listening-socket array (upstream commit a016529,
  via the Pi-hole fork). Patches 0008 to 0010: upstream has merged
  nothing since 2026-04-19, so the open PRs are carried here.
- Authors@R names every individual the bundled sources credit as an
  author, not only their copyright holders: the three Mbed TLS modules
  with a Doxygen \author tag (Adriaan de Jong, Daniel King, Mathias
  Olsson) and Simon Tatham, who wrote the accelerated SHA-512 in Mbed
  TLS for PuTTY. No Face Press, LLC and F-Secure Corporation, which
  CivetWeb's LICENSE.md names as copyright holders, are `cph`.
  inst/civetweb/LICENSE.md now carries only the CivetWeb section of
  that file, not the licences of the Lua, SQLite, Duktape and zlib
  components this package does not bundle. inst/COPYRIGHTS lists the
  same per file. CRAN's review of 0.1.1 asked for this.
- A connection is closed with a FIN, not a reset. The server set
  linger_timeout_ms = 0, so civetweb closed every HTTP connection with
  SO_LINGER {on, 0}: a reset right behind the response, which a client
  reading through an event loop (dart:io) saw before the response and
  reported as "Broken pipe", about one request in ten.

# civetwebR 0.1.1

- No pragma in the bundled sources suppresses a compiler diagnostic
  any more. CRAN's incoming check flagged the 23 in CivetWeb and 3 in
  Mbed TLS as a NOTE, which a new submission cannot carry.
  tools/patches/0007 and tools/patches/mbedtls/0001 replace each with
  a comment, and tools/vendor-mbedtls.sh now applies its patches as
  vendor-civetweb.sh does. What they hid: five static helpers CivetWeb
  leaves unused in this configuration, which gcc -Wall reports as
  defined but not used; R does not count that as significant.

# civetwebR 0.1.0

First CRAN release. civetwebR began as vedoa/civetwebR, an embedded
HTTP server for R over CivetWeb. This release is the cornball-ai fork,
taken over with the original author's go-ahead (vedoa/civetwebR#1) to
be the HTTP and WebSocket transport under glinty. What changed from
the original, by area:

**Event API.** `start_server()` returns a handle; `next_event()`
returns one event, an HTTP request or a WebSocket connect, open,
message or close; `send_response()` answers a request or a connect;
`ws_send()`, `ws_close()` and `server_port()` take the handle.
`serve()` and `run_server()` are loops over it. All state is per
server (an external pointer with a finalizer), so one R process runs
several, and `start_server(register = FALSE)` returns a handle without
making it the default. Port 0 asks the OS for a free port, and the
handle prints the port it got.

**WebSocket.** The connect is routed through R before the handshake,
so an `Origin` or cookie check can refuse an upgrade with a status,
and the refusal is a whole response head. Every event carries
`remote_addr` and `remote_port`; frames carry `fin`, `binary` and
`opcode`, and continuations are delivered. CivetWeb answers pings
itself and echoes a client's close frame with its code before the
`ws_close` event (RFC 6455). `ws_path` chooses the upgrade path and
`keep_alive` keeps HTTP connections open.

**TLS.** `tls_cert`, a PEM file holding the certificate and key, makes
the port speak https and wss through the bundled Mbed TLS 3.6.7,
compiled into the shared object; `has_tls()` reports it.

**Static files.** `static_dirs` maps URL prefixes to directories that
CivetWeb serves itself, with byte ranges, never reaching R. The R-side
`static_files()` handler is unchanged.

**Hardening.** A request carrying both `Transfer-Encoding` and
`Content-Length` is refused with 400 before it reaches R (RFC 7230).
`stop_server()` answers pending requests with 503 and lets the workers
write those answers before CivetWeb stops. Fixed from the original:
`Rf_error()` was called from worker threads on allocation failure,
`ws_send()` could write to a connection being closed, and
`run_server()` errored on Ctrl-C instead of returning. In the bundled
CivetWeb (tools/patches/): `sprintf()` goes through `mg_snprintf()`,
logging no longer writes to stderr or files, the pragma R CMD check
flags is gone, 64-bit formats compile under Rtools, and a ranged
static file is read from the right offset on macOS. The suite runs
under valgrind and under AddressSanitizer with
UndefinedBehaviorSanitizer, in CI and locally (tools/sanitize.sh).

**Tooling.** tinytest, tinyrox, rformat and tinypkgr. CI: r-ci on
Linux and macOS, Rtools on Windows, and the r-hub sanitizer and
valgrind containers. `tools/vendor-civetweb.sh` and
`tools/vendor-mbedtls.sh` re-fetch the bundled libraries at their
pinned versions, and inst/COPYRIGHTS lists every holder in them.
