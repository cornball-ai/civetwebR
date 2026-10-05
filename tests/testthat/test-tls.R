# ------------------------------------------------------------------------------
# TLS through the bundled Mbed TLS. The certificate is generated on the fly
# with the openssl command-line tool and the client is the curl command-line
# tool; the round-trip test skips when either is missing.
# ------------------------------------------------------------------------------

# A one-day self-signed certificate for 127.0.0.1 and its key, in the one
# PEM file CivetWeb expects.
tls_fixture <- function() {
  openssl <- Sys.which("openssl")
  if (!nzchar(openssl)) skip("openssl command-line tool not available")
  dir <- tempfile("tls")
  dir.create(dir)
  key <- file.path(dir, "key.pem")
  crt <- file.path(dir, "crt.pem")
  status <- system2(
    openssl,
    c("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
      "-subj", "/CN=127.0.0.1", "-keyout", shQuote(key), "-out", shQuote(crt)),
    stdout = FALSE, stderr = FALSE
  )
  if (!identical(status, 0L)) skip("could not generate a test certificate")
  pem <- file.path(dir, "server.pem")
  writeLines(c(readLines(crt), readLines(key)), pem)
  pem
}

# curl_bg() lives in helper-drive.R.

test_that("has_tls() is TRUE with the bundled Mbed TLS", {
  expect_true(has_tls())
})

test_that("tls_cert must be NULL or an existing file", {
  expect_error(start_server(port = 0L, register = FALSE, tls_cert = 1),
               "tls_cert")
  expect_error(start_server(port = 0L, register = FALSE,
                            tls_cert = tempfile("nope")),
               "does not exist")
})

test_that("a server with tls_cert answers https and refuses plain http", {
  skip_on_cran()
  skip_if_not_installed("callr")
  pem <- tls_fixture()

  srv <- start_server(port = 0L, register = FALSE, tls_cert = pem)
  on.exit(stop_server(srv), add = TRUE)
  port <- server_port(srv)
  expect_gt(port, 0L)
  expect_true(srv$tls)
  expect_output(print(srv), "https://127.0.0.1")

  p <- curl_bg(c("-sk", "--max-time", "10",
                 sprintf("https://127.0.0.1:%d/secure?x=1", port)))
  on.exit(if (p$is_alive()) p$kill(), add = TRUE)
  seen <- drive_until(
    srv,
    function(ev) ev$event == "request",
    function(ev) list(status = 200L, body = paste0("tls ", ev$path, "?", ev$query)),
    timeout = 10
  )
  ev <- seen[[length(seen)]]
  expect_equal(ev$path, "/secure")
  expect_equal(ev$remote_addr, "127.0.0.1")
  p$wait(10000)
  res <- p$get_result()
  expect_null(res$status)
  expect_equal(res$out, "tls /secure?x=1")

  # Plain HTTP on the TLS port: curl fails and nothing reaches R.
  q <- curl_bg(c("-s", "--max-time", "5",
                 sprintf("http://127.0.0.1:%d/plain", port)))
  on.exit(if (q$is_alive()) q$kill(), add = TRUE)
  deadline <- Sys.time() + 5
  got_request <- FALSE
  while (Sys.time() < deadline && q$is_alive()) {
    ev <- next_event(50L, srv)
    if (!is.null(ev) && ev$event == "request") {
      got_request <- TRUE
      send_response(ev$id, "should not happen", srv)
    }
  }
  expect_false(got_request)
  q$wait(5000)
  expect_false(is.null(q$get_result()$status))
})
