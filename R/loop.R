# Internal native wrappers (native symbols; required with R_forceSymbols(TRUE))

# Event type codes from server.c
.EVENT_NAMES <- c("0" = "request", "1" = "ws_connect", "2" = "ws_open",
                  "3" = "ws_message", "4" = "ws_close")

.next_request <- function(timeout_ms = 100L, server = NULL) {
    req <- .Call(civetweb_next_request_timeout, .server_ptr(server),
                 as.integer(timeout_ms), PACKAGE = "civetwebR")

    if (is.list(req) && !isTRUE(req$interrupted)) {
        req$event <- unname(.EVENT_NAMES[as.character(req$type)])
        class(req) <- "cw_request"
    }
    req
}

.send_response <- function(id, res, server = NULL) {
    .Call(civetweb_send_response, .server_ptr(server), as.integer(id), res,
          PACKAGE = "civetwebR")
}

# Ctrl-C arrives from C as a sentinel, because the check that notices it
# must not longjmp out of C. Raise it here as a real interrupt condition:
# tryCatch(interrupt = ) catches it, and unhandled it ends the call.
.raise_interrupt <- function() {
    cond <- structure(class = c("interrupt", "condition"),
                      list(message = "interrupted", call = NULL))
    stop(cond)
}

#' Wait for the next event
#'
#' The low-level driver: one call returns one event from a server, or
#' \code{NULL} after \code{timeout_ms} with nothing to do.
#' \code{run_server()} and \code{serve()} are loops over this; an
#' application with its own event loop calls it directly.
#'
#' Events are lists of class \code{cw_request} with an \code{event}
#' field:
#'
#' \itemize{
#' \item \code{"request"}: an HTTP request. \code{method}, \code{path},
#'   \code{query}, \code{headers} (named character), \code{body} (raw),
#'   \code{body_too_large}, \code{remote_addr}, \code{remote_port}. Must
#'   be answered with \code{send_response()}; the worker thread waits
#'   until then.
#' \item \code{"ws_connect"}: a client asks to upgrade on the WebSocket
#'   path. Same fields as a request. Must be answered with
#'   \code{send_response()}: \code{TRUE} accepts, \code{FALSE} refuses
#'   with 403, a list with a \code{status} refuses with that status.
#'   Nothing is sent to the client until R decides, so this is where an
#'   \code{Origin} or cookie check belongs.
#' \item \code{"ws_open"}: the handshake completed for the connection
#'   with this \code{id}.
#' \item \code{"ws_message"}: a data frame arrived. \code{body} (raw),
#'   \code{binary}, \code{fin} and \code{opcode} (1 text, 2 binary, 0
#'   continuation). A message split across frames arrives as several
#'   events: the first with the text or binary opcode, the rest as
#'   continuations, the last with \code{fin = TRUE}; the receiver
#'   concatenates the bodies.
#' \item \code{"ws_close"}: the connection with this \code{id} is gone.
#' }
#'
#' A WebSocket connection keeps the \code{id} of its connect event for
#' its whole life; \code{ws_send()} and \code{ws_close()} address it by
#' that id.
#'
#' Control frames never reach R: CivetWeb answers a ping with a pong,
#' and a close frame from the client is echoed back with its status
#' code before the \code{ws_close} event (RFC 6455 section 5.5.1).
#'
#' On Ctrl-C an \code{interrupt} condition is signalled.
#'
#' @param timeout_ms Milliseconds to wait for an event. Default 100.
#' @param server A server handle from \code{start_server()}, or NULL for
#'   the default server.
#' @return A \code{cw_request}, or \code{NULL} on timeout.
#' @examples
#' srv <- start_server(port = 0L, register = FALSE)
#' # one turn of an event loop: nothing arrives within 10 ms, so NULL
#' ev <- next_event(10L, srv)
#' is.null(ev)
#' stop_server(srv)
#'
#' \dontrun{
#' # the loop an application runs, until interrupted
#' repeat {
#'     ev <- next_event(100L, srv)
#'     if (is.null(ev)) next
#'     switch(ev$event,
#'            request    = send_response(ev$id, "ok", srv),
#'            ws_connect = send_response(ev$id, TRUE, srv),
#'            ws_message = ws_send(ev$id, ev$body, srv))
#' }
#' }
#' @export
next_event <- function(timeout_ms = 100L, server = NULL) {
    timeout_ms <- .validate_timeout_ms(timeout_ms)
    req <- .next_request(timeout_ms, server)
    if (is.list(req) && isTRUE(req$interrupted)) {
        .raise_interrupt()
    }
    req
}

#' Answer a request or a WebSocket connect
#'
#' @param id The event's \code{id}.
#' @param res For a request: a string (200, text/plain) or a list with
#'   \code{status}, \code{headers} and \code{body} (character or raw).
#'   For a WebSocket connect: \code{TRUE} to accept, \code{FALSE} to
#'   refuse with 403, or a list with a \code{status} to refuse with that
#'   status.
#' @inheritParams next_event
#' @return NULL, invisibly.
#' @examples
#' srv <- start_server(port = 0L, register = FALSE)
#' ev <- next_event(10L, srv)
#' if (!is.null(ev) && ev$event == "request") {
#'     send_response(ev$id, list(status = 200L, body = "ok"), srv)
#' }
#' stop_server(srv)
#' @export
send_response <- function(id, res, server = NULL) {
    .send_response(id, res, server)
    invisible(NULL)
}

#' Send a WebSocket message
#' @param id Connection ID.
#' @param data Character string or raw vector.
#' @inheritParams next_event
#' @return \code{TRUE} if the frame was written, \code{FALSE} if the
#'   connection is not open.
#' @examples
#' srv <- start_server(port = 0L, register = FALSE)
#' # no connection has this id, so nothing is written
#' ws_send(1L, "hello", srv)
#' stop_server(srv)
#' @export
ws_send <- function(id, data, server = NULL) {
    .Call(civetweb_ws_send, .server_ptr(server), as.integer(id), data,
          PACKAGE = "civetwebR")
}

#' Close a WebSocket connection from the server side
#'
#' Sends a close frame with \code{code}; the client answers and the
#' connection ends, which arrives later as a \code{ws_close} event.
#' Further \code{ws_send()} calls on the id return \code{FALSE}.
#'
#' @param id Connection ID.
#' @param code Integer close code. Default 1000 (normal closure).
#' @inheritParams next_event
#' @return \code{TRUE} if the close frame was written.
#' @examples
#' srv <- start_server(port = 0L, register = FALSE)
#' # no connection has this id, so nothing is written
#' ws_close(1L, 1000L, srv)
#' stop_server(srv)
#' @export
ws_close <- function(id, code = 1000L, server = NULL) {
    .Call(civetweb_ws_close, .server_ptr(server), as.integer(id),
          as.integer(code), PACKAGE = "civetwebR")
}

#' Run the CivetWeb driver loop (single-thread safe mode)
#'
#' This loop pulls requests from C, dispatches in R, and sends responses back.
#' It runs until interrupted.
#'
#' @param timeout_ms Polling timeout in milliseconds. Default is 100ms.
#' @return Invisibly returns TRUE when the loop exits.
#' @examples
#' \dontrun{
#' # runs until Ctrl-C
#' handle("GET", "/", function(req) "hello")
#' start_server(port = 8080L)
#' run_server()
#' stop_server()
#' }
#' @export
run_server <- function(timeout_ms = 100L) {
    if (!.is_running()) {
        stop("Server is not running", call. = FALSE)
    }
    if (.is_loop_running()) {
        stop("Server loop is already running", call. = FALSE)
    }

    timeout_ms <- .validate_timeout_ms(timeout_ms)

    .set_loop_running(TRUE)
    on.exit(.set_loop_running(FALSE), add = TRUE)

    repeat {
        req <- .next_request(timeout_ms)

        if (is.list(req) && isTRUE(req$interrupted)) {
            break
        }

        if (is.null(req)) {
            next
        }

        if (req$type == 0L) {
            # HTTP
            res <- .dispatch_request(req$method, req$path, req = req)
            .send_response(req$id, res)
        } else {
            # WebSocket events (CONNECT, READY, DATA, CLOSE)
            .dispatch_ws_event(req)
        }
    }

    invisible(TRUE)
}
