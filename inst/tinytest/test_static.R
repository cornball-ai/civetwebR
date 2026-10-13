# The R-side static handler, static_files(): mounts, traversal, index
# fallback; then one end-to-end run through serve().

.validate_static <- civetwebR:::.validate_static

handler_for <- function(cfg) {
    static <- .validate_static(cfg)
    static_files(dir = static[[1]]$dir, prefix = static[[1]]$prefix,
                 index = static[[1]]$index)
}

# --- a single mount serves a file, its index, and 404 ---

local({
    public <- file.path(tempdir(), "public")
    dir.create(public, showWarnings = FALSE)
    writeLines("hello world", file.path(public, "hello.txt"))
    writeLines("<h1>index</h1>", file.path(public, "index.html"))

    h <- handler_for(list(dir = public, prefix = "/"))

    res <- h(list(path = "/hello.txt"))
    expect_equal(res$status, 200L)
    expect_match(rawToChar(res$body), "hello world")

    res <- h(list(path = "/"))
    expect_equal(res$status, 200L)
    expect_match(rawToChar(res$body), "index")

    res <- h(list(path = "/missing.txt"))
    expect_equal(res$status, 404L)
})

# --- several mounts sort so the longer prefix wins ---

local({
    tmp <- tempdir()
    public <- file.path(tmp, "public")
    assets <- file.path(tmp, "assets")
    dir.create(public, showWarnings = FALSE)
    dir.create(assets, showWarnings = FALSE)
    writeLines("root", file.path(public, "file.txt"))
    writeLines("asset", file.path(assets, "file.txt"))

    static <- .validate_static(list(list(dir = public, prefix = "/"),
                                    list(dir = assets, prefix = "/assets")))
    handlers <- lapply(static, function(s) {
        static_files(dir = s$dir, prefix = s$prefix, index = s$index)
    })

    req <- list(path = "/assets/file.txt")
    res <- NULL
    for (i in seq_along(handlers)) {
        if (startsWith(req$path, static[[i]]$prefix)) {
            res <- handlers[[i]](req)
            break
        }
    }

    # from /assets, not /
    expect_equal(res$status, 200L)
    expect_match(rawToChar(res$body), "asset")
})

# --- directory traversal is refused ---

local({
    tmp <- tempdir()
    public <- file.path(tmp, "public")
    dir.create(public, showWarnings = FALSE)
    writeLines("secret", file.path(tmp, "secret.txt"))

    h <- handler_for(list(dir = public, prefix = "/"))
    res <- h(list(path = "/../secret.txt"))
    expect_equal(res$status, 403L)
})

# --- the index fallback tries each name in order ---

local({
    public <- file.path(tempdir(), "public")
    dir.create(public, showWarnings = FALSE)
    writeLines("alt index", file.path(public, "default.html"))

    h <- handler_for(list(dir = public, prefix = "/",
                          index = c("default.html", "index.html")))
    res <- h(list(path = "/"))
    expect_equal(res$status, 200L)
    expect_match(rawToChar(res$body), "alt index")
})

# --- end to end through serve() ---
# Local-only: sockets, a spawnable R and wall-clock time.

if (!at_home()) exit_file("socket tests run at home")
if (!requireNamespace("callr", quietly = TRUE)) exit_file("callr not installed")
source("helper_server.R", local = TRUE)

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
    # url() warns about the 404 before it errors
    expect_error(suppressWarnings(http_get(port, "/does-not-exist")))
})
