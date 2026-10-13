# Shared helpers for the tests that run serve() in a background R
# process and talk to it over a socket. A test file sources this with
# source("helper_server.R", local = TRUE).

# Poll a port until something accepts a connection, the server child
# dies, or the deadline passes.
wait_for_server <- function(port, p = NULL, timeout = 5) {
    start <- Sys.time()
    repeat {
        if (!is.null(p) && !p$is_alive()) {
            stop("Server crashed:\n", p$read_error())
        }
        # a refused connection is a warning and an error; neither is news
        ok <- suppressWarnings(tryCatch({
            con <- socketConnection(host = "127.0.0.1", port = port,
                                    open = "r+", blocking = TRUE)
            close(con)
            TRUE
        }, error = function(e) FALSE))
        if (ok) return(TRUE)
        if (as.numeric(Sys.time() - start, units = "secs") > timeout) {
            stop("Server did not start")
        }
        Sys.sleep(0.05)
    }
}

# serve() in a background R process running the installed civetwebR
# (the child takes this process's library paths, so a scratch library
# is honoured). `setup` runs in the child before serve(), with the
# package attached, and must use only its own arguments: it is given
# the child's global environment, as callr gives the function it runs.
# `...` goes to serve(). The caller waits on the port and kills the
# child.
serve_bg <- function(port, setup = function() NULL, ...) {
    environment(setup) <- globalenv()
    callr::r_bg(function(lib_paths, port, setup, args) {
        .libPaths(lib_paths)
        library(civetwebR)
        setup()
        do.call(serve,
                c(list(port = port, host = "127.0.0.1", quiet = TRUE), args))
    }, args = list(.libPaths(), port, setup, list(...)))
}

# One GET over R's url() connection, the body as one string.
http_get <- function(port, path) {
    con <- url(sprintf("http://127.0.0.1:%d%s", port, path))
    on.exit(close(con), add = TRUE)
    paste(readLines(con, warn = FALSE), collapse = "\n")
}

# One raw HTTP exchange over a socket: the request text as written, the
# whole response as lines. The request should carry Connection: close.
http_raw <- function(port, request) {
    con <- socketConnection(host = "127.0.0.1", port = port, open = "r+",
                            blocking = TRUE)
    on.exit(close(con), add = TRUE)
    writeChar(request, con, eos = NULL)
    flush(con)
    readLines(con, warn = FALSE)
}
