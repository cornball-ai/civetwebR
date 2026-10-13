% tinyrox says don't edit this manually, but it can't stop you!
\name{server_port}
\alias{server_port}
\title{The port a server is listening on}
\usage{
server_port(server = NULL)
}
\arguments{
\item{server}{A server handle from \code{start_server()}, or NULL for
the default server.}
}
\value{
Integer port.
}
\description{
Useful after \code{start_server(port = 0)}.
}
