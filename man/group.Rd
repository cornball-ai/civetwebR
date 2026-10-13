% tinyrox says don't edit this manually, but it can't stop you!
\name{group}
\alias{group}
\title{Register handlers under a common path prefix}
\usage{
group(prefix, expr)
}
\arguments{
\item{prefix}{Character(1). Path prefix (e.g. "/api/v1").}

\item{expr}{Code that registers handlers.}
}
\value{
Invisibly returns TRUE.
}
\description{
Register handlers under a common path prefix
}
\examples{
group("/api", {
    handle("GET", "/users", function(req) "[]")
    handle("GET", "/status", function(req) "ok")
})
# registered as /api/users and /api/status
clear_handlers()
}
