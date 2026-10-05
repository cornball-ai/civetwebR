# The curl command-line tool in a background R process, as the HTTP
# client where R's own socket reads proved unportable (macOS returned
# early mid-response). The result has the exit status (NULL for 0) and
# the output lines.
curl_bg <- function(args) {
  if (!nzchar(Sys.which("curl"))) skip("curl command-line tool not available")
  callr::r_bg(
    function(args) {
      out <- suppressWarnings(system2("curl", args, stdout = TRUE, stderr = TRUE))
      list(status = attr(out, "status"), out = paste(out, collapse = "\n"),
           lines = as.character(out))
    },
    args = list(args)
  )
}

# Drive a server until `pred(ev)` is TRUE or the deadline passes; every
# "request" and "ws_connect" event is answered by `answer(ev)` on the way.
# Returns every event seen.
drive_until <- function(server, pred, answer, timeout = 5) {
  deadline <- Sys.time() + timeout
  seen <- list()
  while (Sys.time() < deadline) {
    ev <- next_event(50L, server)
    if (is.null(ev)) next
    seen[[length(seen) + 1L]] <- ev
    if (ev$event %in% c("request", "ws_connect")) {
      send_response(ev$id, answer(ev), server)
    }
    if (isTRUE(pred(ev))) return(seen)
  }
  stop("timed out waiting for an event")
}
