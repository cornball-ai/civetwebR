% tinyrox says don't edit this manually, but it can't stop you!
\name{run_server}
\alias{run_server}
\title{Run the CivetWeb driver loop (single-thread safe mode)}
\usage{
run_server(timeout_ms = 100L)
}
\arguments{
\item{timeout_ms}{Polling timeout in milliseconds. Default is 100ms.}
}
\value{
Invisibly returns TRUE when the loop exits.
}
\description{
This loop pulls requests from C, dispatches in R, and sends responses back.
It runs until interrupted.
}
\examples{
\dontrun{
# runs until Ctrl-C
handle("GET", "/", function(req) "hello")
start_server(port = 8080L)
run_server()
stop_server()
}
}
