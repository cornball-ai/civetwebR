#' Start the CivetWeb server
#'
#' Starts a server and, by default, registers it as the package's default
#' server, the one `run_server()`, `serve()`, `ws_send()` and friends use
#' when no `server` is given. With `register = FALSE` the server is only
#' returned, so one R process can run several.
#'
#' @param port Integer. Port to listen on; `0` lets the OS choose (see
#'   `server_port()`).
#' @param host String. Host to expose to.
#' @param num_threads Integer. Number of worker threads. Default is 50.
#' @param max_body_size Number. Maximum request body size in bytes. Default is 8MiB.
#' @param request_timeout_ms Integer. Socket receive timeout. Default is 30s.
#' @param ws_path String. The path WebSocket upgrades are accepted on.
#'   Default `"/ws"`.
#' @param static_dirs NULL or a named character vector mapping URL prefixes
#'   to directories, e.g. `c("/assets/" = "www")`. Requests under these
#'   prefixes are served by CivetWeb itself, with byte ranges, and never
#'   reach R. Distinct from the R-side `static` argument of `serve()`.
#' @param keep_alive Logical. Keep HTTP connections open between requests.
#'   Default `FALSE`.
#' @param register Logical. Make this the default server. Default `TRUE`.
#' @return A server handle (class `cw_server`), invisibly.
#' @export
start_server <- function(
  port = 8080L,
  host = "127.0.0.1",
  num_threads = 50L,
  max_body_size = 8 * 1024 * 1024,
  request_timeout_ms = 30000L,
  ws_path = "/ws",
  static_dirs = NULL,
  keep_alive = FALSE,
  register = TRUE
) {
  if (isTRUE(register)) {
    .validate_is_running()
  }
  port <- .validate_port(port)
  host <- .validate_host(host)
  num_threads <- .validate_num_threads(num_threads)
  max_body_size <- .validate_max_body_size(max_body_size)
  request_timeout_ms <- .validate_request_timeout_ms(request_timeout_ms)
  ws_path <- .validate_ws_path(ws_path)
  static_dirs <- .validate_static_dirs(static_dirs)
  keep_alive <- .validate_keep_alive(keep_alive)

  ptr <- .Call(
    civetweb_start_server,
    port,
    host,
    num_threads,
    as.numeric(max_body_size),
    request_timeout_ms,
    ws_path,
    names(static_dirs),
    unname(static_dirs),
    keep_alive,
    PACKAGE = "civetwebR"
  )

  if (is.null(ptr)) {
    stop("failed to start server", call. = FALSE)
  }

  handle <- structure(
    list(ptr = ptr, host = host, port = port, ws_path = ws_path),
    class = "cw_server"
  )

  if (isTRUE(register)) {
    .state$server_xptr <- ptr
    .state$server <- handle
    .set_loop_running(FALSE)
  }

  invisible(handle)
}

#' Stop a CivetWeb server
#'
#' Answers every request still waiting on R with 503, closes the
#' connections and releases the server. Stopping the default server clears
#' it.
#'
#' @param server A server handle from `start_server()`, or NULL for the
#'   default server.
#' @return Invisibly returns TRUE.
#' @export
stop_server <- function(server = NULL) {
  if (is.null(server)) {
    .validate_is_not_running()
    ptr <- .state$server_xptr
    .Call(civetweb_stop_server, ptr, PACKAGE = "civetwebR")
    .state$server_xptr <- NULL
    .state$server <- NULL
    .set_loop_running(FALSE)
    return(invisible(TRUE))
  }

  ptr <- .server_ptr(server)
  .Call(civetweb_stop_server, ptr, PACKAGE = "civetwebR")
  if (identical(ptr, .state$server_xptr)) {
    .state$server_xptr <- NULL
    .state$server <- NULL
    .set_loop_running(FALSE)
  }
  invisible(TRUE)
}

#' The port a server is listening on
#'
#' Useful after `start_server(port = 0)`.
#'
#' @inheritParams stop_server
#' @return Integer port.
#' @export
server_port <- function(server = NULL) {
  .Call(civetweb_server_port, .server_ptr(server), PACKAGE = "civetwebR")
}

#' @export
print.cw_server <- function(x, ...) {
  running <- .Call(civetweb_server_running, x$ptr, PACKAGE = "civetwebR")
  cat("<cw_server> http://", x$host, ":", x$port, "  ",
      if (running) "running" else "stopped", "\n", sep = "")
  invisible(x)
}

# Resolve a server argument to its external pointer.
.server_ptr <- function(server) {
  if (is.null(server)) {
    if (!.is_running()) {
      stop("Server is not running", call. = FALSE)
    }
    return(.state$server_xptr)
  }
  if (inherits(server, "cw_server")) {
    return(server$ptr)
  }
  if (typeof(server) == "externalptr") {
    return(server)
  }
  stop("server must be a cw_server handle or NULL", call. = FALSE)
}
