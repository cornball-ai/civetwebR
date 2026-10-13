# Integration: serve() in a background R process, driven over sockets
# from this one. Local-only: sockets, a spawnable R and wall-clock
# time.

if (!at_home()) exit_file("socket tests run at home")
if (!requireNamespace("callr", quietly = TRUE)) exit_file("callr not installed")
source("helper_server.R", local = TRUE)

# --- static serving ---

local({
    tmp <- tempdir()
    public <- file.path(tmp, "public")
    assets <- file.path(tmp, "assets")
    dir.create(public, showWarnings = FALSE)
    dir.create(assets, showWarnings = FALSE)
    writeLines("root-file", file.path(public, "file.txt"))
    writeLines("asset-file", file.path(assets, "file.txt"))
    writeLines("INDEX", file.path(public, "index.html"))

    port <- sample(10000:20000, 1)
    p <- serve_bg(port, static = list(list(dir = public, prefix = "/"),
                                      list(dir = assets, prefix = "/assets")))
    on.exit(if (p$is_alive()) p$kill(), add = TRUE)
    wait_for_server(port, p)

    expect_match(http_get(port, "/file.txt"), "root-file", fixed = TRUE)
    expect_match(http_get(port, "/assets/file.txt"), "asset-file", fixed = TRUE)
    expect_match(http_get(port, "/"), "INDEX", fixed = TRUE)
})

# --- routing ---

local({
    port <- sample(10000:20000, 1)
    p <- serve_bg(port, setup = function() {
        handle("GET", "/hello", function(req) "HELLO")
        group("/api", {
            handle("GET", "/world", function(req) "WORLD")
        })
    })
    on.exit(if (p$is_alive()) p$kill(), add = TRUE)
    wait_for_server(port, p)

    expect_match(http_get(port, "/hello"), "HELLO", fixed = TRUE)
    expect_match(http_get(port, "/api/world"), "WORLD", fixed = TRUE)
})

# --- static overrides routing where they overlap ---

local({
    tmp <- tempdir()
    public <- file.path(tmp, "public")
    dir.create(public, showWarnings = FALSE)
    dir.create(file.path(public, "api"), showWarnings = FALSE)
    writeLines("STATIC", file.path(public, "api", "hello"))

    port <- sample(10000:20000, 1)
    p <- serve_bg(port,
                  setup = function() handle("GET", "/api/hello", function(req) "ROUTE"),
                  static = list(list(dir = public, prefix = "/")))
    on.exit(if (p$is_alive()) p$kill(), add = TRUE)
    wait_for_server(port, p)

    expect_match(http_get(port, "/api/hello"), "STATIC", fixed = TRUE)
})

# --- custom headers and status codes ---

local({
    port <- sample(10000:20000, 1)
    p <- serve_bg(port, setup = function() {
        handle("GET", "/custom", function(req) {
            list(status = 201L, headers = list("X-Test-Header" = "civetwebR"),
                 body = "status-201")
        })
    })
    on.exit(if (p$is_alive()) p$kill(), add = TRUE)
    wait_for_server(port, p)

    lines <- http_raw(port,
                      "GET /custom HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
    # 201 Created (HTTP/1.0 if CivetWeb did not upgrade the connection)
    expect_true(any(grepl("HTTP/1\\.[01] 201", lines)))
    # the custom header propagates
    expect_true(any(grepl("X-Test-Header: civetwebR", lines)))
    # the default Content-Type, added in C when R gives none
    expect_true(any(grepl("Content-Type: text/plain", lines)))
})

# --- a custom status text ---

local({
    port <- sample(10000:20000, 1)
    p <- serve_bg(port, setup = function() {
        handle("GET", "/teapot", function(req) {
            list(status = 418L, status_text = "I am a coffee pot",
                 body = "short and stout")
        })
    })
    on.exit(if (p$is_alive()) p$kill(), add = TRUE)
    wait_for_server(port, p)

    lines <- http_raw(port,
                      "GET /teapot HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
    expect_match(lines[1], "418 I am a coffee pot", fixed = TRUE)
})

# --- max_body_size and the body_too_large flag ---

local({
    port <- sample(10000:20000, 1)
    p <- serve_bg(port, setup = function() {
        handle("POST", "/check-size", function(req) {
            # the flag and the length actually received
            list(status = 200L,
                 headers = list("X-Body-Large" = as.character(req$body_too_large)),
                 body = as.character(length(req$body)))
        })
    }, max_body_size = 50)
    on.exit(if (p$is_alive()) p$kill(), add = TRUE)
    wait_for_server(port, p)

    post <- function(payload) {
        http_raw(port, sprintf(paste0(
                                      "POST /check-size HTTP/1.1\r\nHost: 127.0.0.1\r\n",
                                      "Content-Length: %d\r\nConnection: close\r\n\r\n%s"),
                               nchar(payload), payload))
    }

    # within the limit: 5 bytes
    res1 <- post("12345")
    expect_true(any(grepl("X-Body-Large: FALSE", res1)))
    expect_equal(tail(res1, 1), "5")

    # over the limit: 100 bytes, truncated to 50 and flagged
    res2 <- post(strrep("a", 100))
    expect_true(any(grepl("X-Body-Large: TRUE", res2)))
    expect_equal(tail(res2, 1), "50")
})
