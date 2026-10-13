% tinyrox says don't edit this manually, but it can't stop you!
\name{req_header}
\alias{req_header}
\title{Helper to extract a header from a request}
\usage{
req_header(req, key)
}
\arguments{
\item{req}{A cw_request object.}

\item{key}{Header name, matched without regard to case.}
}
\value{
The header's value as a string, or NULL when the request has
  no such header.
}
\description{
Helper to extract a header from a request
}
\examples{
req <- structure(list(headers = c("Content-Type" = "application/json")),
                 class = "cw_request")
req_header(req, "content-type")
req_header(req, "Accept")
}
