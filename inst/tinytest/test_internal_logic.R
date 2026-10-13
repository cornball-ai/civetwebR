# Internal helpers: path normalization, prefix matching, WebSocket
# event dispatch, MIME guessing and the directory-listing breadcrumb.

.normalize_path <- civetwebR:::.normalize_path
.prefix_match <- civetwebR:::.prefix_match
.dispatch_ws_event <- civetwebR:::.dispatch_ws_event
.guess_mime <- civetwebR:::.guess_mime
.breadcrumb <- civetwebR:::.breadcrumb

# --- path normalization ---

expect_error(.normalize_path("a/b"))
expect_equal(.normalize_path("/a/b?q=1"), "/a/b?q=1")
expect_error(.normalize_path(NULL))
expect_error(.normalize_path(NA_character_))

# --- prefix matching respects folder boundaries ---

expect_true(.prefix_match("/api/v1", "/api"))
expect_false(.prefix_match("/api-v1", "/api"))
expect_true(.prefix_match("/", "/"))

# --- WebSocket event dispatch reaches every registered type ---

clear_handlers()
calls <- integer()
on_ws("open", function(req) calls <<- c(calls, 2L))
on_ws("message", function(req) calls <<- c(calls, 3L))
.dispatch_ws_event(list(type = 2L))
.dispatch_ws_event(list(type = 3L))
expect_equal(calls, c(2L, 3L))
clear_handlers()

# --- MIME guessing ---

expect_equal(.guess_mime("test.json"), "application/json")
expect_equal(.guess_mime("test.css"), "text/css")
expect_equal(.guess_mime("test.unknown"), "application/octet-stream")

# --- the breadcrumb is valid HTML with one link per level ---

res <- .breadcrumb("/api/v1/users")
expect_match(res, 'href="/api/"', fixed = TRUE)
expect_match(res, 'href="/api/v1/"', fixed = TRUE)
expect_match(res, 'href="/api/v1/users/"', fixed = TRUE)
