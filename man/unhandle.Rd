% tinyrox says don't edit this manually, but it can't stop you!
\name{unhandle}
\alias{unhandle}
\title{Unregister an HTTP handler}
\usage{
unhandle(method, path)
}
\arguments{
\item{method}{Character string. HTTP method (e.g. "GET").}

\item{path}{Character string. Route path.}
}
\value{
TRUE (invisibly) on success.
}
\description{
Removes a function for a given HTTP method and path.
}
