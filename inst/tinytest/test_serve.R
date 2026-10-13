# serve(): argument validation, before anything listens.

expect_error(serve(port = NA), pattern = "port")
expect_error(serve(port = 99999), pattern = "port")
expect_error(serve(host = NA), pattern = "host")
expect_error(serve(host = ""), pattern = "host")
expect_error(serve(quiet = NA), pattern = "quiet")
expect_error(serve(log = 123), pattern = "log")
