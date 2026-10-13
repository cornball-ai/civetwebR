% tinyrox says don't edit this manually, but it can't stop you!
\name{ws_close}
\alias{ws_close}
\title{Close a WebSocket connection from the server side}
\usage{
ws_close(id, code = 1000L, server = NULL)
}
\arguments{
\item{id}{Connection ID.}

\item{code}{Integer close code. Default 1000 (normal closure).}

\item{server}{A server handle from \code{start_server()}, or NULL for
the default server.}
}
\value{
\code{TRUE} if the close frame was written.
}
\description{
Sends a close frame with \code{code}; the client answers and the
connection ends, which arrives later as a \code{ws_close} event.
Further \code{ws_send()} calls on the id return \code{FALSE}.
}
\examples{
srv <- start_server(port = 0L, register = FALSE)
# no connection has this id, so nothing is written
ws_close(1L, 1000L, srv)
stop_server(srv)
}
