% tinyrox says don't edit this manually, but it can't stop you!
\name{serve}
\alias{serve}
\title{Start and run the HTTP server}
\usage{
serve(
  port = 8080L,
  host = "127.0.0.1",
  quiet = FALSE,
  log = NULL,
  static = NULL,
  timeout_ms = 100L,
  num_threads = 50L,
  max_body_size = 8 * 1024 * 1024,
  request_timeout_ms = 30000L,
  ws_path = "/ws",
  keep_alive = FALSE,
  tls_cert = NULL
)
}
\arguments{
\item{port}{Integer. Port to listen on.}

\item{host}{Character(1). Bind address.}

\item{quiet}{Logical. Suppress startup message.}

\item{log}{Function or NULL. Optional request logger.}

\item{static}{NULL or list. Static serving configuration(s).}

\item{timeout_ms}{Polling timeout in milliseconds. Default is 100ms.}

\item{num_threads}{Integer. Number of worker threads. Default is 50.}

\item{max_body_size}{Number. Maximum request body size in bytes. Default is 8MiB.}

\item{request_timeout_ms}{Integer. Socket receive timeout. Default is 30s.}

\item{ws_path}{String. The path WebSocket upgrades are accepted on.
Default \code{"/ws"}.}

\item{keep_alive}{Logical. Keep HTTP connections open between
requests. Default \code{FALSE}.}

\item{tls_cert}{NULL, or the path of a PEM file holding the server's
certificate and private key; see \code{\link{start_server}}.}
}
\value{
Invisibly returns TRUE when the loop exits.
}
\description{
Start and run the HTTP server
}
\examples{
\dontrun{
# runs until Ctrl-C
handle("GET", "/", function(req) "hello")
serve(port = 8080L)
}
}
