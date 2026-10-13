% tinyrox says don't edit this manually, but it can't stop you!
\name{static_files}
\alias{static_files}
\title{Static file handler (serves files from a directory)}
\usage{
static_files(
  dir,
  prefix = "/",
  index = c("index.html"),
  cache_control = NULL,
  list_dirs = FALSE,
  template = NULL
)
}
\arguments{
\item{dir}{Character(1). Root directory to serve from.}

\item{prefix}{Character(1). URL prefix.}

\item{index}{Character vector. Index files.}

\item{cache_control}{NULL or character(1).}

\item{list_dirs}{Logical. Enable directory listing.}

\item{template}{Character(1) or NULL. Optional template path override.}
}
\value{
A handler: a function of a request that returns a response
  list (\code{status}, \code{headers}, raw \code{body}), as
  \code{serve(static = )} installs it.
}
\description{
Static file handler (serves files from a directory)
}
\examples{
www <- tempfile("www")
dir.create(www)
writeLines("<h1>hi</h1>", file.path(www, "index.html"))
h <- static_files(www, prefix = "/")
res <- h(list(path = "/index.html"))
res$status
rawToChar(res$body)
h(list(path = "/missing.html"))$status
unlink(www, recursive = TRUE)
}
