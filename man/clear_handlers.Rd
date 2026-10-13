% tinyrox says don't edit this manually, but it can't stop you!
\name{clear_handlers}
\alias{clear_handlers}
\title{Clear all registered handlers}
\usage{
clear_handlers()
}
\value{
Invisibly returns TRUE.
}
\description{
Removes every HTTP handler and every WebSocket event handler.
}
\examples{
handle("GET", "/a", function(req) "a")
on_ws("message", function(req) ws_send(req$id, req$body))
clear_handlers()
}
