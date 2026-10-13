# Handler registration, dispatch, query parsing and the request context
# a handler sees. All in-process, no sockets.

.get_handler <- civetwebR:::.get_handler
.dispatch_request <- civetwebR:::.dispatch_request
.parse_query <- civetwebR:::.parse_query
.get_handlers_env <- civetwebR:::.get_handlers_env

# --- registration ---

clear_handlers()
handle("GET", "/a", function(req) "ok")
expect_true(is.function(.get_handler("GET", "/a")))

# a duplicate errors when overwriting is refused
clear_handlers()
handle("GET", "/a", function(req) "ok")
expect_error(handle("GET", "/a", function(req) "again", overwrite = FALSE))

# different methods may share a path
clear_handlers()
handle("GET", "/a", function(req) "get")
handle("POST", "/a", function(req) "post")
expect_true(is.function(.get_handler("GET", "/a")))
expect_true(is.function(.get_handler("POST", "/a")))

# --- dispatch ---

clear_handlers()
handle("GET", "/a", function(req) "ok")
res <- .dispatch_request("GET", "/a")
expect_equal(res$status, 200L)
expect_equal(res$body, "ok")

# a missing route is 404
clear_handlers()
res <- .dispatch_request("GET", "/missing")
expect_equal(res$status, 404L)

# a handler error is 500
clear_handlers()
handle("GET", "/a", function(req) stop("boom"))
res <- .dispatch_request("GET", "/a")
expect_equal(res$status, 500L)

# a string response is normalized
clear_handlers()
handle("GET", "/a", function(req) "ok")
res <- .dispatch_request("GET", "/a")
expect_equal(res$status, 200L)
expect_true(is.list(res$headers))
expect_equal(res$body, "ok")

# a raw response passes through
clear_handlers()
handle("GET", "/bin", function(req) {
    list(status = 200L,
        headers = list("Content-Type" = "application/octet-stream"),
        body = charToRaw("abc"))
})
res <- .dispatch_request("GET", "/bin")
expect_equal(res$status, 200L)
expect_true(is.raw(res$body))

# group() applies its prefix
clear_handlers()
group("/api", {
    handle("GET", "/x", function(req) "ok")
})
expect_true(is.function(.get_handler("GET", "/api/x")))

# --- query parsing ---

expect_equal(.parse_query("a=1"), list(a = "1"))
expect_equal(.parse_query("a=1&b=2"), list(a = "1", b = "2"))
expect_equal(.parse_query("flag"), list(flag = ""))
expect_equal(.parse_query("name=tom%20lee"), list(name = "tom lee"))

# --- request context ---

# query_params are available in a handler
clear_handlers()
handle("GET", "/test", function(req) req$query_params$name)
res <- .dispatch_request("GET", "/test", list(query = "name=tom"))
expect_equal(res$body, "tom")

# headers are available in a handler
clear_handlers()
handle("GET", "/h", function(req) req$headers[["X-Test"]])
res <- .dispatch_request("GET", "/h", req = list(headers = c("X-Test" = "ok")))
expect_equal(res$body, "ok")

# the body is available in a handler, raw
clear_handlers()
handle("POST", "/b", function(req) rawToChar(req$body))
res <- .dispatch_request("POST", "/b", req = list(body = charToRaw("abc")))
expect_equal(res$body, "abc")

# query_params, headers and body all at once
clear_handlers()
handle("POST", "/all", function(req) {
    paste(req$query_params$a, req$headers[["X-T"]], rawToChar(req$body),
        sep = "|")
})
req <- list(query = "a=1", headers = c("X-T" = "t"), body = charToRaw("z"))
res <- .dispatch_request("POST", "/all", req = req)
expect_equal(res$body, "1|t|z")

# --- overwrite and unhandle ---

clear_handlers()
h1 <- function(req) "h1"
h2 <- function(req) "h2"

handle("GET", "/test", h1)
expect_identical(.get_handler("GET", "/test"), h1)

# the default is overwrite = TRUE
handle("GET", "/test", h2)
expect_identical(.get_handler("GET", "/test"), h2)

# overwrite = FALSE errors
expect_error(handle("GET", "/test", h1, overwrite = FALSE),
    pattern = "handler exists")

# the method is case-insensitive
handle("post", "/test", h1)
expect_identical(.get_handler("POST", "/test"), h1)

# unhandle() removes one method, then the path's entry once empty
clear_handlers()
handle("GET", "/test", h1)
handle("POST", "/test", h1)
expect_identical(.get_handler("GET", "/test"), h1)
expect_identical(.get_handler("POST", "/test"), h1)

unhandle("GET", "/test")
expect_null(.get_handler("GET", "/test"))
expect_identical(.get_handler("POST", "/test"), h1)

unhandle("POST", "/test")
expect_null(.get_handler("POST", "/test"))
expect_false(exists("/test", envir = .get_handlers_env(), inherits = FALSE))

clear_handlers()
