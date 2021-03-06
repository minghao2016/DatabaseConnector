% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/Andromeda.R
\name{querySqlToAndromeda}
\alias{querySqlToAndromeda}
\title{Retrieves data to a local Andromeda database}
\usage{
querySqlToAndromeda(
  connection,
  sql,
  andromeda,
  andromedaTableName,
  errorReportFile = file.path(getwd(), "errorReportSql.txt"),
  snakeCaseToCamelCase = FALSE,
  integer64AsNumeric = getOption("databaseConnectorInteger64AsNumeric", default = TRUE)
)
}
\arguments{
\item{connection}{The connection to the database server.}

\item{sql}{The SQL to be sent.}

\item{andromeda}{An open connection to a Andromeda database, for example as created using \code{\link[Andromeda]{andromeda}}.}

\item{andromedaTableName}{The name of the table in the local Andromeda database where the results of the query will be stored.}

\item{errorReportFile}{The file where an error report will be written if an error occurs. Defaults to
'errorReportSql.txt' in the current working directory.}

\item{snakeCaseToCamelCase}{If true, field names are assumed to use snake_case, and are converted to camelCase.}

\item{integer64AsNumeric}{Logical: should 64-bit integers be converted to numeric (double) values? If FALSE
64-bit integers will be represented using \code{bit64::integer64}.}
}
\value{


Invisibly returns the andromeda. The Andromeda database will have a table added with the query results.
}
\description{
This function sends SQL to the server, and returns the results in a local Andromeda database.
}
\details{
Retrieves data from the database server and stores it in a local Andromeda database. This allows very large
data sets to be retrieved without running out of memory. If an error occurs during SQL execution,
this error is written to a file to facilitate debugging. Null values in the database are converted
to NA values in R.If a table with the same name already exists in the local Andromeda database it is replaced.
}
\examples{
\dontrun{
andromeda <- Andromeda::andromeda()
connectionDetails <- createConnectionDetails(dbms = "postgresql",
                                             server = "localhost",
                                             user = "root",
                                             password = "blah",
                                             schema = "cdm_v4")
conn <- connect(connectionDetails)
querySqlToAndromeda(connection = conn, 
                    sql = "SELECT * FROM person;", 
                    andromeda = andromeda,
                    andromedaTableName = "foo")
disconnect(conn)

andromeda$foo
}
}
