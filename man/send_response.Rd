% tinyrox says don't edit this manually, but it can't stop you!
\name{send_response}
\alias{send_response}
\title{Answer a request or a WebSocket connect}
\usage{
send_response(id, res, server = NULL)
}
\arguments{
\item{id}{The event's \code{id}.}

\item{res}{For a request: a string (200, text/plain) or a list with
\code{status}, \code{headers} and \code{body} (character or raw).
For a WebSocket connect: \code{TRUE} to accept, \code{FALSE} to
refuse with 403, or a list with a \code{status} to refuse with that
status.}

\item{server}{A server handle from \code{start_server()}, or NULL for
the default server.}
}
\value{
NULL, invisibly.
}
\description{
Answer a request or a WebSocket connect
}
