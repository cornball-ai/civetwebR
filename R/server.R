#' Start the CivetWeb server
#'
#' Starts a server and, by default, registers it as the package's default
#' server, the one \code{run_server()}, \code{serve()}, \code{ws_send()}
#' and friends use when no \code{server} is given. With
#' \code{register = FALSE} the server is only returned, so one R process
#' can run several.
#'
#' @param port Integer. Port to listen on; \code{0} lets the OS choose
#'   (see \code{server_port()}).
#' @param host String. Host to expose to.
#' @param num_threads Integer. Number of worker threads. Default is 50.
#' @param max_body_size Number. Maximum request body size in bytes.
#'   Default is 8MiB.
#' @param request_timeout_ms Integer. Socket receive timeout. Default is
#'   30s.
#' @param ws_path String. The path WebSocket upgrades are accepted on.
#'   Default \code{"/ws"}.
#' @param static_dirs NULL or a named character vector mapping URL
#'   prefixes to directories, e.g. \code{c("/assets/" = "www")}. Requests
#'   under these prefixes are served by CivetWeb itself, with byte
#'   ranges, and never reach R. Distinct from the R-side \code{static}
#'   argument of \code{serve()}.
#' @param keep_alive Logical. Keep HTTP connections open between
#'   requests. Default \code{FALSE}.
#' @param tls_cert NULL, or the path of a PEM file holding the server's
#'   certificate (followed by its chain, if any) and its private key. When
#'   given, the port speaks TLS (https and wss) through the bundled Mbed
#'   TLS, and a plain-HTTP client on it is refused.
#' @param register Logical. Make this the default server. Default
#'   \code{TRUE}.
#' @return A server handle (class \code{cw_server}), invisibly.
#' @examples
#' # port 0: the OS picks a free port; register = FALSE: a handle only
#' srv <- start_server(port = 0L, register = FALSE)
#' srv
#' server_port(srv)
#' stop_server(srv)
#'
#' # a directory served by CivetWeb itself, never reaching R
#' www <- tempfile("www")
#' dir.create(www)
#' writeLines("hi", file.path(www, "index.html"))
#' srv <- start_server(port = 0L, register = FALSE,
#'                     static_dirs = c("/assets/" = www))
#' stop_server(srv)
#' unlink(www, recursive = TRUE)
#' @export
start_server <- function(port = 8080L, host = "127.0.0.1", num_threads = 50L,
                         max_body_size = 8 * 1024 * 1024,
                         request_timeout_ms = 30000L, ws_path = "/ws",
                         static_dirs = NULL, keep_alive = FALSE,
                         tls_cert = NULL, register = TRUE) {
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
    tls_cert <- .validate_tls_cert(tls_cert)

    ptr <- .Call(civetweb_start_server, port, host, num_threads,
                 as.numeric(max_body_size), request_timeout_ms, ws_path,
                 names(static_dirs), unname(static_dirs), keep_alive,
                 tls_cert, PACKAGE = "civetwebR")

    if (is.null(ptr)) {
        stop("failed to start server", call. = FALSE)
    }

    handle <- structure(
                        list(ptr = ptr, host = host, port = port, ws_path = ws_path,
                             tls = !is.null(tls_cert)),
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
#' @param server A server handle from \code{start_server()}, or NULL for
#'   the default server.
#' @return Invisibly returns TRUE.
#' @examples
#' srv <- start_server(port = 0L, register = FALSE)
#' stop_server(srv)
#'
#' # the default server
#' start_server(port = 0L)
#' stop_server()
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
#' Useful after \code{start_server(port = 0)}.
#'
#' @inheritParams stop_server
#' @return Integer port.
#' @examples
#' srv <- start_server(port = 0L, register = FALSE)
#' server_port(srv)
#' stop_server(srv)
#' @export
server_port <- function(server = NULL) {
    .Call(civetweb_server_port, .server_ptr(server), PACKAGE = "civetwebR")
}

#' Was TLS compiled in?
#'
#' TRUE when the package was built with TLS support, which the bundled Mbed
#' TLS sources provide on every platform.
#'
#' @return Logical.
#' @examples
#' has_tls()
#' @export
has_tls <- function() {
    .Call(civetweb_has_tls, PACKAGE = "civetwebR")
}

#' @exportS3Method print cw_server
print.cw_server <- function(x, ...) {
    running <- .Call(civetweb_server_running, x$ptr, PACKAGE = "civetwebR")
    scheme <- if (isTRUE(x$tls)) "https" else "http"
    # port 0 asked the OS to choose; show what it chose while it lives
    port <- if (running && identical(as.integer(x$port), 0L)) {
        server_port(x)
    } else {
        x$port
    }
    cat("<cw_server> ", scheme, "://", x$host, ":", port, "  ",
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
