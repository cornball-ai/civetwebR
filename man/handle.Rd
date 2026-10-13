% tinyrox says don't edit this manually, but it can't stop you!
\name{handle}
\alias{handle}
\title{Register an HTTP handler}
\usage{
handle(method, path, fun, overwrite = TRUE)
}
\arguments{
\item{method}{Character string. HTTP method (e.g. "GET", "POST").}

\item{path}{Character string. Route path starting with "/".}

\item{fun}{Function. Handler of form function(req).}

\item{overwrite}{Logical. If TRUE (default), overwrite existing handler.}
}
\value{
TRUE (invisibly) on success.
}
\description{
Registers a function for a given HTTP method and path. The path is
normalized and combined with the current route prefix.
}
\examples{
# a string is a 200 text/plain response
handle("GET", "/hello", function(req) "hello world")
# a list sets the status, headers and body
handle("POST", "/echo", function(req) {
    list(status = 200L, headers = list("Content-Type" = "text/plain"),
         body = req$body)
})
clear_handlers()
}
