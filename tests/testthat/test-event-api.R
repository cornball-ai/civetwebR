# ------------------------------------------------------------------------------
# Event API: next_event() / send_response() driven in-process, with clients
# in background R processes. Servers use port 0 and register = FALSE so
# several can coexist and nothing collides with the default server.
# ------------------------------------------------------------------------------

# drive_until() lives in helper-drive.R.

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
  # the whole response head, not just an error body: a client waiting
  # for the status line must see it
  expect_match(p$get_result()$status, "^HTTP/1\\.1 403")
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

# A client that exercises the RFC 6455 details a browser relies on: a
# text message split over two frames, a ping, and a close it initiates.
ws_client_rfc <- function(port) {
  callr::r_bg(
    function(port, ws_handshake) {
      con <- socketConnection("127.0.0.1", port, open = "r+b", blocking = TRUE)
      on.exit(close(con))
      key <- as.raw(c(1, 2, 3, 4))
      frame <- function(opcode, payload, fin = TRUE) {
        mask <- rep_len(as.integer(key), length(payload))
        masked <- as.raw(bitwXor(as.integer(payload), mask))
        c(as.raw(c((if (fin) 0x80 else 0x00) + opcode, 0x80 + length(payload))),
          key, masked)
      }
      read_frame <- function() {
        hdr <- readBin(con, "raw", 2L)
        n <- as.integer(hdr[2]) %% 128L
        list(opcode = as.integer(hdr[1]) %% 16L,
             payload = if (n > 0L) readBin(con, "raw", n) else raw(0))
      }
      out <- list(status = ws_handshake(con))
      # "ab" as a non-final text frame, "cd" as the final continuation
      writeBin(c(frame(0x1, charToRaw("ab"), fin = FALSE),
                 frame(0x0, charToRaw("cd"))), con)
      flush(con)
      out$echo <- rawToChar(read_frame()$payload)
      writeBin(frame(0x9, charToRaw("marco")), con)
      flush(con)
      f <- read_frame()
      out$pong <- list(opcode = f$opcode, payload = rawToChar(f$payload))
      writeBin(frame(0x8, as.raw(c(0x03, 0xE8))), con)
      flush(con)
      f <- read_frame()
      out$close <- list(opcode = f$opcode, payload = as.integer(f$payload))
      repeat {
        chunk <- readBin(con, "raw", 1L)
        if (length(chunk) == 0L) break
      }
      out$eof <- TRUE
      out
    },
    args = list(port, ws_handshake)
  )
}

test_that("fragmented text arrives with opcodes, pings are answered, a client close is echoed", {
  skip_on_cran()
  skip_if_not_installed("callr")

  srv <- start_server(port = 0L, register = FALSE)
  on.exit(stop_server(srv), add = TRUE)
  port <- server_port(srv)

  p <- ws_client_rfc(port)
  on.exit(if (p$is_alive()) p$kill(), add = TRUE)

  parts <- raw(0)
  seen <- drive_until(
    srv,
    function(ev) {
      if (ev$event == "ws_message") {
        expect_false(ev$binary)
        parts <<- c(parts, ev$body)
        if (ev$fin) {
          ws_send(ev$id, rawToChar(parts), srv)
          parts <<- raw(0)
        }
      }
      ev$event == "ws_close"
    },
    function(ev) TRUE,
    timeout = 10
  )
  msgs <- Filter(function(e) e$event == "ws_message", seen)
  expect_equal(vapply(msgs, function(e) e$opcode, 1L), c(1L, 0L))
  expect_equal(vapply(msgs, function(e) e$fin, NA), c(FALSE, TRUE))

  p$wait(10000)
  res <- p$get_result()
  expect_match(res$status, "101")
  expect_equal(res$echo, "abcd")
  # the pong came from civetweb; no ws_message event carried the ping
  expect_equal(res$pong$opcode, 10L)
  expect_equal(res$pong$payload, "marco")
  # the close echo carries the client's status code (1000)
  expect_equal(res$close$opcode, 8L)
  expect_equal(res$close$payload, c(3L, 232L))
  expect_true(res$eof)
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

  # -i: status line and headers first, then the 3-byte body as the
  # last line. (R's socket reads returned early on macOS; see curl_bg.)
  p <- curl_bg(c("-s", "-i", "--max-time", "10", "-r", "2-4",
                 sprintf("http://127.0.0.1:%d/assets/digits.txt", port)))
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
  expect_null(res$status)
  expect_match(res$lines[1], "206")
  expect_equal(res$lines[length(res$lines)], "234")
})

test_that("a request with both Transfer-Encoding and Content-Length is refused with 400 before reaching R", {
  skip_on_cran()
  skip_if_not_installed("callr")

  srv <- start_server(port = 0L, register = FALSE)
  on.exit(stop_server(srv), add = TRUE)
  port <- server_port(srv)

  p <- callr::r_bg(
    function(port) {
      con <- socketConnection("127.0.0.1", port, open = "r+b", blocking = TRUE)
      on.exit(close(con))
      writeLines(c("POST /x HTTP/1.1", "Host: x",
                   "Transfer-Encoding: chunked", "Content-Length: 5",
                   "", "0", ""), con, sep = "\r\n")
      flush(con)
      readLines(con, n = 1L, warn = FALSE)
    },
    args = list(port)
  )
  on.exit(if (p$is_alive()) p$kill(), add = TRUE)

  deadline <- Sys.time() + 3
  got_request <- FALSE
  while (Sys.time() < deadline && p$is_alive()) {
    ev <- next_event(50L, srv)
    if (!is.null(ev) && ev$event == "request") {
      got_request <- TRUE
      send_response(ev$id, "should not happen", srv)
    }
  }
  expect_false(got_request)

  p$wait(5000)
  expect_match(p$get_result(), "400")
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
