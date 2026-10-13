# The default server: start and stop, and the state behind them. Port
# 0 so nothing collides.

.state <- civetwebR:::.state
stop_default <- function() if (!is.null(.state$server_xptr)) stop_server()

# --- starting sets the state ---

stop_default()
start_server(0L)
expect_false(is.null(.state$server_xptr))

# --- stopping clears it ---

stop_default()
start_server(0L)
stop_server()
expect_null(.state$server_xptr)

# --- a second default server is refused ---

stop_default()
start_server(0L)
expect_error(start_server(0L))
stop_server()

# --- stopping a server that is not running is an error ---

stop_default()
expect_error(stop_server())
