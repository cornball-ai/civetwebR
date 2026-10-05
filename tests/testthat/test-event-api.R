# ------------------------------------------------------------------------------
# Event API: next_event() / send_response() driven in-process, with clients
# in background R processes. Servers use port 0 and register = FALSE so
# several can coexist and nothing collides with the default server.
# ------------------------------------------------------------------------------

# Drive a server until `pred(ev)` is TRUE or the deadline passes; every
# "request" and "ws_connect" event is answered by `answer(ev)` on the way.
drive_until <- function(server, pred, answer, timeout = 5) {
  deadline <- Sys.time() + timeout
  seen <- list()
  while (Sys.time() < deadline) {
    ev <- next_event(50L, server)
    if (is.null(ev)) next
    seen[[length(seen) + 1L]] <- ev
    if (ev$event %in% c("request", "ws_connect")) {
      send_response(ev$id, answer(ev), server)
    }
    if (isTRUE(pred(ev))) return(seen)
  }
  stop("timed out waiting for an event")
}

bg_get <- function(port, path) {
  callr::r_bg(
    function(port, path) {
      url <- sprintf("http://127.0.0.1:%d%s", port, path)
      con <- url(url, open = "rb")
      on.exit(close(con))
      rawToChar(readBin(con, "raw", 1e6))
    },
    args = list(port, path)
  )
}

test_that("a request round-trips through next_event() and send_response()", {
  skip_on_cran()
  skip_if_not_installed("callr")

  srv <- start_server(port = 0L, register = FALSE)
  on.exit(stop_server(srv), add = TRUE)
  port <- server_port(srv)
  expect_gt(port, 0L)

  p <- bg_get(port, "/hello?x=1")
  on.exit(if (p$is_alive()) p$kill(), add = TRUE)

  seen <- drive_until(
    srv,
    function(ev) ev$event == "request",
    function(ev) list(status = 200L, body = paste0("got ", ev$path, "?", ev$query))
  )
  ev <- seen[[length(seen)]]
  expect_s3_class(ev, "cw_request")
  expect_equal(ev$method, "GET")
  expect_equal(ev$path, "/hello")
  expect_equal(ev$query, "x=1")
  expect_equal(ev$remote_addr, "127.0.0.1")
  expect_true(is.integer(ev$remote_port) && ev$remote_port > 0L)

  p$wait(5000)
  expect_equal(p$get_result(), "got /hello?x=1")
})

test_that("two servers run side by side in one process", {
  skip_on_cran()
  skip_if_not_installed("callr")

  a <- start_server(port = 0L, register = FALSE)
  b <- start_server(port = 0L, register = FALSE)
  on.exit({ stop_server(a); stop_server(b) }, add = TRUE)
  expect_false(server_port(a) == server_port(b))

  pa <- bg_get(server_port(a), "/")
  pb <- bg_get(server_port(b), "/")
  on.exit({ if (pa$is_alive()) pa$kill(); if (pb$is_alive()) pb$kill() }, add = TRUE)

  drive_until(a, function(ev) ev$event == "request", function(ev) "from a")
  drive_until(b, function(ev) ev$event == "request", function(ev) "from b")
  pa$wait(5000); pb$wait(5000)
  expect_equal(pa$get_result(), "from a")
  expect_equal(pb$get_result(), "from b")
})

test_that("stop_server() answers a pending request with 503 and frees the worker", {
  skip_on_cran()
  skip_if_not_installed("callr")

  srv <- start_server(port = 0L, register = FALSE)
  port <- server_port(srv)
  p <- callr::r_bg(
    function(port) {
      con <- socketConnection("127.0.0.1", port, open = "r+b", blocking = TRUE)
      on.exit(close(con))
      writeLines(c("GET /slow HTTP/1.1", "Host: x", ""), con, sep = "\r\n")
      flush(con)
      readLines(con, n = 1L, warn = FALSE)
    },
    args = list(port)
  )
  on.exit(if (p$is_alive()) p$kill(), add = TRUE)

  # Take the request off the queue and deliberately never answer it.
  deadline <- Sys.time() + 5
  ev <- NULL
  while (is.null(ev) && Sys.time() < deadline) ev <- next_event(50L, srv)
  expect_equal(ev$event, "request")

  stop_server(srv)
  p$wait(5000)
  expect_match(p$get_result(), "503")
})

# A minimal client-side WebSocket handshake over a raw socket.
ws_handshake <- function(con, origin = NULL, path = "/ws") {
  lines <- c(
    sprintf("GET %s HTTP/1.1", path),
    "Host: 127.0.0.1",
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
    "Sec-WebSocket-Version: 13"
  )
  if (!is.null(origin)) lines <- c(lines, paste0("Origin: ", origin))
  writeLines(c(lines, ""), con, sep = "\r\n")
  flush(con)
  status <- readLines(con, n = 1L, warn = FALSE)
  repeat {
    line <- readLines(con, n = 1L, warn = FALSE)
    if (length(line) == 0L || line == "" || line == "\r") break
  }
  status
}

ws_client <- function(port, origin, then = "exit") {
  callr::r_bg(
    function(port, origin, then, ws_handshake) {
      con <- socketConnection("127.0.0.1", port, open = "r+b", blocking = TRUE)
      on.exit(close(con))
      status <- ws_handshake(con, origin)
      if (!grepl("101", status)) return(list(status = status))
      # masked text frame "hi": the mask repeats over the payload, and the
      # payload must not be recycled up to the mask's length
      key <- as.raw(c(1, 2, 3, 4))
      payload <- charToRaw("hi")
      mask <- rep_len(as.integer(key), length(payload))
      masked <- as.raw(bitwXor(as.integer(payload), mask))
      writeBin(c(as.raw(c(0x81, 0x80 + length(payload))), key, masked), con)
      flush(con)
      # read one unmasked text frame back
      hdr <- readBin(con, "raw", 2L)
      body <- readBin(con, "raw", as.integer(hdr[2]))
      closed_by_server <- FALSE
      if (then == "wait_close") {
        # the server sends a close frame; answer it (RFC 6455 closing
        # handshake), then read until EOF
        hdr2 <- readBin(con, "raw", 2L)
        if (length(hdr2) == 2L && as.integer(hdr2[1]) == 0x88) {
          closed_by_server <- TRUE
          readBin(con, "raw", as.integer(hdr2[2]) %% 128L)
          writeBin(c(as.raw(c(0x88, 0x80)), key), con)
          flush(con)
        }
        repeat {
          chunk <- readBin(con, "raw", 1L)
          if (length(chunk) == 0L) break
        }
      }
      list(status = status, echo = rawToChar(body),
           closed_by_server = closed_by_server)
    },
    args = list(port, origin, then, ws_handshake)
  )
}

test_that("a WebSocket connect is refused before the handshake when R says no", {
  skip_on_cran()
  skip_if_not_installed("callr")

  srv <- start_server(port = 0L, register = FALSE)
  on.exit(stop_server(srv), add = TRUE)
  port <- server_port(srv)

  p <- ws_client(port, origin = "http://evil.example")
  on.exit(if (p$is_alive()) p$kill(), add = TRUE)

  seen <- drive_until(
    srv,
    function(ev) ev$event == "ws_connect",
    function(ev) {
      origin <- ev$headers[["Origin"]]
      if (identical(origin, "http://evil.example")) FALSE else TRUE
    }
  )
  ev <- seen[[length(seen)]]
  expect_equal(ev$event, "ws_connect")
  expect_equal(ev$headers[["Origin"]], "http://evil.example")
  expect_equal(ev$remote_addr, "127.0.0.1")

  p$wait(5000)
  expect_match(p$get_result()$status, "403")
})

test_that("an accepted WebSocket keeps one id from connect to close, and ws_send/ws_close work", {
  skip_on_cran()
  skip_if_not_installed("callr")

  srv <- start_server(port = 0L, register = FALSE)
  on.exit(stop_server(srv), add = TRUE)
  port <- server_port(srv)

  p <- ws_client(port, origin = "http://ok.example", then = "wait_close")
  on.exit(if (p$is_alive()) p$kill(), add = TRUE)

  ids <- integer(0)
  seen <- drive_until(
    srv,
    function(ev) {
      ids <<- c(ids, ev$id)
      if (ev$event == "ws_message") {
        expect_false(ev$binary)
        expect_true(ev$fin)
        expect_true(ws_send(ev$id, paste0("echo:", rawToChar(ev$body)), srv))
        expect_true(ws_close(ev$id, 1000L, srv))
      }
      ev$event == "ws_close"
    },
    function(ev) TRUE
  )
  events <- vapply(seen, function(e) e$event, "")
  expect_equal(events, c("ws_connect", "ws_open", "ws_message", "ws_close"))
  expect_equal(length(unique(ids)), 1L)

  # after close, the id is gone
  expect_false(ws_send(ids[1], "late", srv))

  p$wait(5000)
  res <- p$get_result()
  expect_match(res$status, "101")
  expect_equal(res$echo, "echo:hi")
  expect_true(res$closed_by_server)
})

test_that("static_dirs are served by civetweb with byte ranges, never reaching R", {
  skip_on_cran()
  skip_if_not_installed("callr")

  www <- tempfile("www")
  dir.create(www)
  writeLines("0123456789", file.path(www, "digits.txt"))

  srv <- start_server(port = 0L, register = FALSE,
                      static_dirs = c("/assets/" = www))
  on.exit(stop_server(srv), add = TRUE)
  port <- server_port(srv)

  p <- callr::r_bg(
    function(port) {
      con <- socketConnection("127.0.0.1", port, open = "r+b", blocking = TRUE)
      on.exit(close(con))
      writeLines(c("GET /assets/digits.txt HTTP/1.1", "Host: x",
                   "Range: bytes=2-4", ""), con, sep = "\r\n")
      flush(con)
      status <- readLines(con, n = 1L, warn = FALSE)
      body <- character(0)
      repeat {
        line <- readLines(con, n = 1L, warn = FALSE)
        if (length(line) == 0L) break
        body <- c(body, line)
      }
      list(status = status, tail = body[length(body)])
    },
    args = list(port)
  )
  on.exit(if (p$is_alive()) p$kill(), add = TRUE)

  # Drive the loop: no "request" event may arrive for the static path.
  deadline <- Sys.time() + 3
  got_request <- FALSE
  while (Sys.time() < deadline && p$is_alive()) {
    ev <- next_event(50L, srv)
    if (!is.null(ev) && ev$event == "request") got_request <- TRUE
  }
  expect_false(got_request)

  p$wait(5000)
  res <- p$get_result()
  expect_match(res$status, "206")
  expect_equal(res$tail, "234")
})

test_that("run_server() returns cleanly on interrupt", {
  skip_on_cran()
  skip_if_not_installed("callr")
  skip_on_os("windows")

  pkg_path <- normalizePath(test_path("../.."), mustWork = TRUE)
  p <- callr::r_bg(
    function(lib_paths, pkg_path) {
      .libPaths(lib_paths)
      if (file.exists(file.path(pkg_path, "DESCRIPTION"))) {
        pkgload::load_all(pkg_path, quiet = TRUE)
      } else {
        library(civetwebR)
      }
      start_server(port = 0L)
      run_server(timeout_ms = 10L)
      "clean"
    },
    args = list(.libPaths(), pkg_path)
  )
  on.exit(if (p$is_alive()) p$kill(), add = TRUE)

  Sys.sleep(1.5)
  p$interrupt()
  p$wait(5000)
  expect_false(p$is_alive())
  expect_equal(p$get_result(), "clean")
})
