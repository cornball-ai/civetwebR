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
