# civetwebR

An embedded, high-performance HTTP server for R based on the [CivetWeb](https://github.com/civetweb/civetweb) C library.

## Key Features

- **Thread Safety:** Uses a "Pull" model where multi-threaded C (50 worker threads) handles socket I/O and a single R thread processes logic, ensuring the R interpreter never crashes or deadlocks.
- **WebSockets:** Full support for bi-directional, stateful communication (Connect, Open, Message, and Close events). The connect event runs in R before the handshake, so an `Origin` or cookie check can refuse an upgrade with a status.
- **Routing:** Support for method-based routing and path grouping.
- **Static Content:** Built-in static file serving with directory listing, breadcrumbs, and security guards.

## WebSockets

`civetwebR` makes it easy to build stateful, reactive applications:

```r
on_ws("connect", function(req) {
  # before the handshake: TRUE accepts, FALSE refuses with 403,
  # list(status = 401L) refuses with that status
  identical(req_header(req, "Origin"), "https://app.example")
})

on_ws("open", function(req) {
  message(sprintf("Client %s connected from %s", req$id, req$remote_addr))
})

on_ws("message", function(req) {
  msg <- rawToChar(req$body)
  ws_send(req$id, paste("Echo:", msg))
})

on_ws("close", function(req) {
  message(sprintf("Client %s disconnected", req$id))
})
```

- **Flexible I/O:** Support for custom headers, query parameter parsing, and binary (raw) request/response bodies.
- **Interrupt Friendly:** Fully supports `Ctrl+C` to stop the server gracefully from the R console.

## Installation

```r
# Install from GitHub
# devtools::install_github("vedoa/civetwebR")
```

## Usage

```r
library(civetwebR)

# Start a server on port 8080
serve(port = 8080, host = "127.0.0.1")
```

## Handlers

```r
handle("GET", "/path", function(req) "ok")
```

## Static Files

Serve files directly from disk:

```r
serve(
  port = 8080,
  static = list(
    list(dir = "public", prefix = "/")
  )
)
```

## Routing Groups

Group routes under a common prefix:

```r
group("/api", {
  handle("GET", "/hello", function(req) "hi")
})
```

## Request

```r
req <- list(
  method = "...",
  path   = "..."
)
```

## Response

**Character:**
```r
"ok"
```

→ 200 text/plain

**List:**
```r
list(
  status = 200L,
  headers = list(),
  body = "data"
)
```

## Event API

`serve()` and `run_server()` are loops over a lower-level driver that an
application with its own event loop can call directly. One call to
`next_event()` returns one event, or `NULL` after the timeout:

```r
srv <- start_server(port = 0L, register = FALSE,
                    static_dirs = c("/assets/" = "www"))
server_port(srv)   # the port the OS chose

repeat {
  ev <- next_event(100L, srv)
  if (is.null(ev)) next
  switch(ev$event,
    request    = send_response(ev$id, list(status = 200L, body = "ok"), srv),
    ws_connect = send_response(ev$id, TRUE, srv),
    ws_open    = message("open ", ev$id, " from ", ev$remote_addr),
    ws_message = ws_send(ev$id, ev$body, srv),
    ws_close   = message("closed ", ev$id)
  )
}
```

- A `request` or `ws_connect` event must be answered with
  `send_response()`; its worker thread waits until then.
- A WebSocket connection keeps the `id` of its connect event for its
  whole life. `ws_send()` writes to it, `ws_close()` sends a close frame,
  and the `ws_close` event arrives once the client has answered it.
- `static_dirs` maps URL prefixes to directories that CivetWeb serves
  itself, with byte ranges; those requests never reach R.
- `start_server(register = FALSE)` returns a handle without making it
  the default server, so one process can run several servers.
- Every event carries `remote_addr` and `remote_port`.
- On Ctrl-C, `next_event()` signals an `interrupt` condition.

## Notes

- All handlers run in the R thread  
- No concurrency in user code  

## TLS

Pass `tls_cert`, a PEM file holding the certificate (and its chain)
followed by the private key, and the port speaks https and wss through
the bundled Mbed TLS:

```r
serve(port = 8443, host = "0.0.0.0", tls_cert = "server.pem")
srv <- start_server(port = 8443, tls_cert = "server.pem")
```

A self-signed certificate for local use:

```sh
openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj /CN=localhost \
  -keyout key.pem -out crt.pem && cat crt.pem key.pem > server.pem
```

`has_tls()` reports whether TLS was compiled in.

## Vendored CivetWeb and Mbed TLS

`src/civetweb.c` and `src/civetweb/*.inl` are CivetWeb at the commit in
`src/civetweb/COMMIT`, with the patches in `tools/patches/` applied:

- `0001-cran-snprintf.patch`: `sprintf()` calls go through
  `mg_snprintf()`, which R CMD check requires.
- `0002-reject-chunked-with-content-length.patch`: a request with both
  `Transfer-Encoding` and `Content-Length` is refused with 400.
- `0003-mbedtls-no-stderr.patch`: the TLS paths report through `mg_cry()`
  instead of stderr.

`src/civetweb/external_mg_cry_internal_impl.inl` replaces CivetWeb's
error logging, which would otherwise write to stderr or a log file.
`tools/vendor-civetweb.sh [<sha>]` re-fetches CivetWeb and reapplies the
patches.

`src/mbedtls/` is Mbed TLS at the release in `src/mbedtls/VERSION`,
fetched and checksum-verified by `tools/vendor-mbedtls.sh [<version>]`.
`src/civetweb/civetwebr_mbedtls_config.h` holds this package's few
changes to its default configuration. Copyright notices for both
libraries are in `inst/COPYRIGHTS`.

## License

MIT