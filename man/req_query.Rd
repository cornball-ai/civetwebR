% tinyrox says don't edit this manually, but it can't stop you!
\name{req_query}
\alias{req_query}
\title{Helper to extract a query parameter from a request}
\usage{
req_query(req, key)
}
\arguments{
\item{req}{A cw_request object.}

\item{key}{Parameter name.}
}
\value{
The parameter's value as a string, or NULL when the query has
  no such parameter.
}
\description{
Helper to extract a query parameter from a request
}
\examples{
req <- structure(list(query_params = list(page = "2")),
                 class = "cw_request")
req_query(req, "page")
req_query(req, "missing")
}
