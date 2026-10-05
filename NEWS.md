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
