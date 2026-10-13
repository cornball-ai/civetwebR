# Input validation: each validator on its own, then the aggregator
# serve() uses.

.validate_port <- civetwebR:::.validate_port
.validate_host <- civetwebR:::.validate_host
.validate_timeout_ms <- civetwebR:::.validate_timeout_ms
.validate_num_threads <- civetwebR:::.validate_num_threads
.validate_max_body_size <- civetwebR:::.validate_max_body_size
.validate_request_timeout_ms <- civetwebR:::.validate_request_timeout_ms
.validate_serve_input <- civetwebR:::.validate_serve_input
.validate_static <- civetwebR:::.validate_static

# --- port ---

expect_equal(.validate_port(8080), 8080L)
expect_error(.validate_port(-1))
expect_error(.validate_port(70000))
expect_error(.validate_port("abc"))

# --- host, with IPv6 literals bracketed ---

expect_equal(.validate_host("127.0.0.1"), "127.0.0.1")
expect_equal(.validate_host("localhost"), "localhost")
expect_equal(.validate_host("::1"), "[::1]")
expect_equal(.validate_host("[::1]"), "[::1]")
expect_error(.validate_host(""))
expect_error(.validate_host("invalid host!"))
expect_error(.validate_host("[invalid]"))

# --- timeout_ms ---

expect_equal(.validate_timeout_ms(100), 100L)
expect_equal(.validate_timeout_ms(0), 0L)
expect_error(.validate_timeout_ms(-10))
expect_error(.validate_timeout_ms("100"))

# --- num_threads ---

expect_equal(.validate_num_threads(5), 5L)
expect_error(.validate_num_threads(0))
expect_error(.validate_num_threads(-1))

# --- max_body_size ---

expect_equal(.validate_max_body_size(1024), 1024)
expect_equal(.validate_max_body_size(1e6), 1e6)
expect_error(.validate_max_body_size(-1))
expect_error(.validate_max_body_size(NA))

# --- request_timeout_ms ---

expect_equal(.validate_request_timeout_ms(30000), 30000L)
expect_error(.validate_request_timeout_ms(-1))

# --- the serve() aggregator ---

args <- .validate_serve_input(8080, "127.0.0.1", TRUE, NULL, 100, 5, 1024, 5000)
expect_equal(args$port, 8080L)
expect_equal(args$num_threads, 5L)
expect_equal(args$max_body_size, 1024)
expect_equal(args$request_timeout_ms, 5000L)

# --- a single static config is wrapped in a list ---

cfg <- list(dir = tempdir(), prefix = "/test")
expect_equal(length(.validate_static(cfg)), 1L)
