% tinyrox says don't edit this manually, but it can't stop you!
\name{stop_server}
\alias{stop_server}
\title{Stop a CivetWeb server}
\usage{
stop_server(server = NULL)
}
\arguments{
\item{server}{A server handle from \code{start_server()}, or NULL for
the default server.}
}
\value{
Invisibly returns TRUE.
}
\description{
Answers every request still waiting on R with 503, closes the
connections and releases the server. Stopping the default server clears
it.
}
\examples{
srv <- start_server(port = 0L, register = FALSE)
stop_server(srv)

# the default server
start_server(port = 0L)
stop_server()
}
