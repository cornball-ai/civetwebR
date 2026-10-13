# run_server(): the refusals before the loop starts.

.state <- civetwebR:::.state
.is_running <- civetwebR:::.is_running
.set_loop_running <- civetwebR:::.set_loop_running

# --- no server running ---

if (.is_running()) stop_server()
expect_error(run_server(), pattern = "Server is not running")

# --- the loop refuses to run twice ---

local({
    # a stand-in pointer satisfies .is_running() without a server
    .state$server_xptr <- TRUE
    on.exit(.state$server_xptr <- NULL)
    .set_loop_running(TRUE)
    on.exit(.set_loop_running(FALSE), add = TRUE)
    expect_error(run_server(), pattern = "Server loop is already running")
})
