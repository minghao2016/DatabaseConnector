# @file InsertTable.R
#
# Copyright 2021 Observational Health Data Sciences and Informatics
#
# This file is part of DatabaseConnector
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

getSqlDataTypes <- function(column) {
  if (is.integer(column)) {
    return("INTEGER")
  } else if (identical(class(column), c("POSIXct", "POSIXt"))) {
    return("DATETIME2")
  } else if (class(column) == "Date") {
    return("DATE")
  } else if (bit64::is.integer64(column)) {
    return("BIGINT")
  } else if (is.numeric(column)) {
    return("FLOAT")
  } else {
    if (is.factor(column)) {
      maxLength <- max(nchar(levels(column)), na.rm = TRUE)
    } else if (all(is.na(column))) {
      maxLength <- NA
    } else {
      maxLength <- max(nchar(as.character(column)), na.rm = TRUE)
    }
    if (is.na(maxLength) || maxLength <= 255) {
      return("VARCHAR(255)")
    } else {
      return(sprintf("VARCHAR(%s)", maxLength))
    }
  }
}

.sql.qescape <- function(s, identifier = FALSE, quote = "\"") {
  s <- as.character(s)
  if (identifier) {
    vid <- grep("^[A-Za-z]+([A-Za-z0-9_]*)$", s)
    if (length(s[-vid])) {
      if (is.na(quote))
        abort(paste0("The JDBC connection doesn't support quoted identifiers, but table/column name contains characters that must be quoted (",
             paste(s[-vid], collapse = ","),
             ")"))
      s[-vid] <- .sql.qescape(s[-vid], FALSE, quote)
    }
    return(s)
  }
  if (is.na(quote))
    quote <- ""
  s <- gsub("\\\\", "\\\\\\\\", s)
  if (nchar(quote))
    s <- gsub(paste("\\", quote, sep = ""), paste("\\\\\\", quote, sep = ""), s, perl = TRUE)
  paste(quote, s, quote, sep = "")
}

validateInt64Insert <- function() {
  # Validate that communication of 64-bit integers with Java is correct:
  values <- bit64::as.integer64(c(1, -1, 8589934592, -8589934592))
  class(values) <- "double"                              
  success <- rJava::J("org.ohdsi.databaseConnector.BatchedInsert")$validateInteger64(values)
  if (!success) {
    abort("Error converting 64-bit integers between R and Java")
  }
}


trySettingAutoCommit <- function(connection, value) {
  tryCatch({
    rJava::.jcall(connection@jConnection, "V", "setAutoCommit", value)
  }, error = function(cond) {
    # do nothing
  })
}

#' Insert a table on the server
#'
#' @description
#' This function sends the data in a data frame to a table on the server. Either a new table
#' is created, or the data is appended to an existing table.
#'
#' @param connection          The connection to the database server.
#' @param databaseSchema      (Optional) The name of the database schema where the table should
#'                            be located. 
#' @param tableName           The name of the table where the data should be inserted.
#' @param data                The data frame containing the data to be inserted.
#' @param dropTableIfExists   Drop the table if the table already exists before writing?
#' @param createTable         Create a new table? If false, will append to existing table.
#' @param tempTable           Should the table created as a temp table?
#' @param oracleTempSchema    DEPRECATED: use \code{tempEmulationSchema} instead.
#' @param tempEmulationSchema Some database platforms like Oracle and Impala do not truly support temp tables. To
#'                            emulate temp tables, provide a schema with write privileges where temp tables
#'                            can be created.
#' @param bulkLoad            If using Redshift, PDW, Hive or Postgres, use more performant bulk loading 
#'                            techniques. Does not work for temp tables (except for HIVE). See Details for 
#'                            requirements for the various platforms.
#' @param useMppBulkLoad      DEPRECATED. Use \code{bulkLoad} instead.
#' @param progressBar         Show a progress bar when uploading?
#' @param camelCaseToSnakeCase If TRUE, the data frame column names are assumed to use camelCase and
#'                             are converted to snake_case before uploading.
#'
#' @details
#' This function sends the data in a data frame to a table on the server. Either a new table is
#' created, or the data is appended to an existing table. NA values are inserted as null values in the
#' database. 
#' 
#' Bulk uploading: 
#' 
#' Redshift: The MPP bulk loading relies upon the CloudyR S3 library
#' to test a connection to an S3 bucket using AWS S3 credentials. Credentials are configured 
#' directly into the System Environment using the following keys: Sys.setenv("AWS_ACCESS_KEY_ID" =
#' "some_access_key_id", "AWS_SECRET_ACCESS_KEY" = "some_secret_access_key", "AWS_DEFAULT_REGION" =
#' "some_aws_region", "AWS_BUCKET_NAME" = "some_bucket_name", "AWS_OBJECT_KEY" = "some_object_key",
#' "AWS_SSE_TYPE" = "server_side_encryption_type"). 
#' 
#' PDW: The MPP bulk loading relies upon the client
#' having a Windows OS and the DWLoader exe installed, and the following permissions granted: --Grant
#' BULK Load permissions - needed at a server level USE master; GRANT ADMINISTER BULK OPERATIONS TO
#' user; --Grant Staging database permissions - we will use the user db. USE scratch; EXEC
#' sp_addrolemember 'db_ddladmin', user; Set the R environment variable DWLOADER_PATH to the location 
#' of the binary.
#' 
#' PostgreSQL:
#' Uses the 'pg' executable to upload. Set the POSTGRES_PATH environment variable  to the Postgres 
#' binary path, e.g. 'C:/Program Files/PostgreSQL/11/bin'.
#'
#' @examples
#' \dontrun{
#' connectionDetails <- createConnectionDetails(dbms = "mysql",
#'                                              server = "localhost",
#'                                              user = "root",
#'                                              password = "blah")
#' conn <- connect(connectionDetails)
#' data <- data.frame(x = c(1, 2, 3), y = c("a", "b", "c"))
#' insertTable(conn, "my_schema", "my_table", data)
#' disconnect(conn)
#'
#' ## bulk data insert with Redshift or PDW
#' connectionDetails <- createConnectionDetails(dbms = "redshift",
#'                                              server = "localhost",
#'                                              user = "root",
#'                                              password = "blah",
#'                                              schema = "cdm_v5")
#' conn <- connect(connectionDetails)
#' data <- data.frame(x = c(1, 2, 3), y = c("a", "b", "c"))
#' insertTable(connection = connection,
#'             databaseSchema = "scratch",
#'             tableName = "somedata",
#'             data = data,
#'             dropTableIfExists = TRUE,
#'             createTable = TRUE,
#'             tempTable = FALSE,
#'             bulkLoad = TRUE)  # or, Sys.setenv("DATABASE_CONNECTOR_BULK_UPLOAD" = TRUE)
#' }
#' @export
insertTable <- function(connection,
                        databaseSchema = NULL,
                        tableName,
                        data,
                        dropTableIfExists = TRUE,
                        createTable = TRUE,
                        tempTable = FALSE,
                        oracleTempSchema = NULL,
                        tempEmulationSchema = getOption("sqlRenderTempEmulationSchema"),
                        bulkLoad = Sys.getenv("DATABASE_CONNECTOR_BULK_UPLOAD"),
                        useMppBulkLoad = Sys.getenv("USE_MPP_BULK_LOAD"),
                        progressBar = FALSE,
                        camelCaseToSnakeCase = FALSE) {
  UseMethod("insertTable", connection)
}

#' @export
insertTable.default <- function(connection,
                                databaseSchema = NULL,
                                tableName,
                                data,
                                dropTableIfExists = TRUE,
                                createTable = TRUE,
                                tempTable = FALSE,
                                oracleTempSchema = NULL,
                                tempEmulationSchema = getOption("sqlRenderTempEmulationSchema"),
                                bulkLoad = Sys.getenv("DATABASE_CONNECTOR_BULK_UPLOAD"),
                                useMppBulkLoad = Sys.getenv("USE_MPP_BULK_LOAD"),
                                progressBar = FALSE,
                                camelCaseToSnakeCase = FALSE) {
  if (!is.null(useMppBulkLoad) && useMppBulkLoad != "") {
    warn("The 'useMppBulkLoad' argument is deprecated. Use 'bulkLoad' instead.",
         .frequency = "regularly",
         .frequency_id = "useMppBulkLoad")
    bulkLoad <- useMppBulkLoad
  }
  bulkLoad <- (!is.null(bulkLoad) && bulkLoad == "TRUE")
  if (!is.null(oracleTempSchema) && oracleTempSchema != "") {
    warn("The 'oracleTempSchema' argument is deprecated. Use 'tempEmulationSchema' instead.",
         .frequency = "regularly",
         .frequency_id = "oracleTempSchema")
    tempEmulationSchema <- oracleTempSchema
  }
  if (camelCaseToSnakeCase) {
    colnames(data) <- SqlRender::camelCaseToSnakeCase(colnames(data))
  }
  if (!tempTable & substr(tableName, 1, 1) == "#") {
    tempTable <- TRUE
    warn("Temp table name detected, setting tempTable parameter to TRUE")
  }
  if (dropTableIfExists)
    createTable <- TRUE
  if (tempTable & substr(tableName, 1, 1) != "#" & attr(connection, "dbms") != "redshift")
    tableName <- paste("#", tableName, sep = "")
  if (!is.null(databaseSchema))
    tableName <- paste(databaseSchema, tableName, sep = ".")
  if (is.vector(data) && !is.list(data))
    data <- data.frame(x = data)
  if (length(data) < 1)
    abort("data must have at least one column")
  if (is.null(names(data)))
    names(data) <- paste("V", 1:length(data), sep = "")
  if (length(data[[1]]) > 0) {
    if (!is.data.frame(data))
      data <- as.data.frame(data, row.names = 1:length(data[[1]]))
  } else {
    if (!is.data.frame(data))
      data <- as.data.frame(data)
  }
  isSqlReservedWord(c(tableName, colnames(data)), warn = TRUE)
  useBulkLoad <- (bulkLoad && connection@dbms == "hive" && createTable) ||
    (bulkLoad && connection@dbms %in% c("redshift", "pdw", "postgresql") && !tempTable)
  useCtasHack <- connection@dbms %in% c("pdw", "redshift", "bigquery", "hive") && createTable && nrow(data) > 0 && !useBulkLoad
  
  sqlDataTypes <- sapply(data, getSqlDataTypes)
  sqlTableDefinition <- paste(.sql.qescape(names(data), TRUE, connection@identifierQuote), sqlDataTypes, collapse = ", ")
  sqlTableName <- .sql.qescape(tableName, TRUE, connection@identifierQuote)
  sqlFieldNames <- paste(.sql.qescape(names(data), TRUE, connection@identifierQuote), collapse = ",")
  
  if (dropTableIfExists) {
    if (tempTable) {
      sql <- "IF OBJECT_ID('tempdb..@tableName', 'U') IS NOT NULL DROP TABLE @tableName;"
    } else {
      sql <- "IF OBJECT_ID('@tableName', 'U') IS NOT NULL DROP TABLE @tableName;"
    }
    renderTranslateExecuteSql(connection = connection, 
                              sql = sql, 
                              tableName = tableName,
                              tempEmulationSchema = tempEmulationSchema,
                              progressBar = FALSE, 
                              reportOverallTime = FALSE)
  }
  
  if (createTable && !useCtasHack && !(bulkLoad && connection@dbms == "hive")) {
    sql <- paste("CREATE TABLE ", sqlTableName, " (", sqlTableDefinition, ");", sep = "")
    renderTranslateExecuteSql(connection = connection, 
                              sql = sql, 
                              tempEmulationSchema = tempEmulationSchema, 
                              progressBar = FALSE, 
                              reportOverallTime = FALSE)
  }
  
  if (useBulkLoad) {
    # Inserting using bulk upload for MPP ------------------------------------------------
    if (!checkBulkLoadCredentials(connection)) {
      abort("Bulk load credentials could not be confirmed. Please review them or set 'bulkLoad' to FALSE")
    }
    inform("Attempting to use bulk loading...")
    if (connection@dbms == "redshift") {
      bulkLoadRedshift(connection, sqlTableName, data)
    } else if (connection@dbms == "pdw") {
      bulkLoadPdw(connection, sqlTableName, sqlDataTypes, data)
    } else if (connection@dbms == "hive") {
      bulkLoadHive(connection, sqlTableName, sqlFieldNames, data)
    } else if (connection@dbms == "postgresql") {
      bulkLoadPostgres(connection, sqlTableName, sqlFieldNames, sqlDataTypes, data) 
    }
  } else if (useCtasHack) {
    # Inserting using CTAS hack ----------------------------------------------------------------
    ctasHack(connection, sqlTableName, tempTable, sqlFieldNames, sqlDataTypes, data, progressBar, tempEmulationSchema)
  } else {
    # Inserting using SQL inserts --------------------------------------------------------------
    if (any(sqlDataTypes == "BIGINT")) {
      validateInt64Insert()
    }
    
    insertSql <- paste0("INSERT INTO ",
                       sqlTableName,
                       " (",
                       sqlFieldNames,
                       ") VALUES(",
                       paste(rep("?", length(sqlDataTypes)), collapse = ","),
                       ")")
    insertSql <- SqlRender::translate(insertSql,
                                      targetDialect = connection@dbms,
                                      oracleTempSchema = tempEmulationSchema)
    batchSize <- 10000
    
    autoCommit <- rJava::.jcall(connection@jConnection, "Z", "getAutoCommit")
    if (autoCommit) {
      trySettingAutoCommit(connection, FALSE)
      on.exit(trySettingAutoCommit(connection, TRUE))
    }
    if (nrow(data) > 0) {
      if (progressBar) {
        pb <- txtProgressBar(style = 3)
      }
      batchedInsert <- rJava::.jnew("org.ohdsi.databaseConnector.BatchedInsert",
                                    connection@jConnection,
                                    insertSql,
                                    ncol(data))
      for (start in seq(1, nrow(data), by = batchSize)) {
        if (progressBar) {
          setTxtProgressBar(pb, start/nrow(data))
        }
        end <- min(start + batchSize - 1, nrow(data))
        setColumn <- function(i, start, end) {
          column <- unlist(data[start:end, i], use.names = FALSE)
          if (is.integer(column)) {
            rJava::.jcall(batchedInsert, "V", "setInteger", i, column)
          } else if (bit64::is.integer64(column)) {
            class(column) <- "numeric"
            rJava::.jcall(batchedInsert, "V", "setBigint", i, column)
          } else if (is.numeric(column)) {
            rJava::.jcall(batchedInsert, "V", "setNumeric", i, column)
          } else if (identical(class(column), c("POSIXct", "POSIXt"))) {
            rJava::.jcall(batchedInsert, "V", "setDateTime", i, as.character(column))
          } else if (class(column) == "Date") {
            rJava::.jcall(batchedInsert, "V", "setDate", i, as.character(column))
          } else {
            rJava::.jcall(batchedInsert, "V", "setString", i, as.character(column))
          }
          return(NULL)
        }
        lapply(1:ncol(data), setColumn, start = start, end = end)
        if (attr(connection, "dbms") == "bigquery") {
          rJava::.jcall(batchedInsert, "V", "executeBigQueryBatch")
        }  else {
          rJava::.jcall(batchedInsert, "V", "executeBatch")
        }
        
      }
      if (progressBar) {
        setTxtProgressBar(pb, 1)
        close(pb)
      }
    }
  }
}

#' @export
insertTable.DatabaseConnectorDbiConnection <- function(connection,
                                                       databaseSchema = NULL,
                                                       tableName,
                                                       data,
                                                       dropTableIfExists = TRUE,
                                                       createTable = TRUE,
                                                       tempTable = FALSE,
                                                       oracleTempSchema = NULL,
                                                       tempEmulationSchema = getOption("sqlRenderTempEmulationSchema"),
                                                       bulkLoad = Sys.getenv("DATABASE_CONNECTOR_BULK_UPLOAD"),
                                                       useMppBulkLoad = Sys.getenv("USE_MPP_BULK_LOAD"),
                                                       progressBar = FALSE,
                                                       camelCaseToSnakeCase = FALSE) {
  if (camelCaseToSnakeCase) {
    colnames(data) <- SqlRender::camelCaseToSnakeCase(colnames(data))
  }
  if (!tempTable & substr(tableName, 1, 1) == "#") {
    tempTable <- TRUE
    warn("Temp table name detected, setting tempTable parameter to TRUE")
  }
  isSqlReservedWord(c(tableName, colnames(data)), warn = TRUE)
  
  tableName <- gsub("^#", "", tableName)
  if (!is.null(databaseSchema)) {
    tableName <- paste(databaseSchema, tableName, sep = ".")
  }
  
  # Convert dates and datetime to UNIX timestamp:
  for (i in 1:ncol(data)) {
    if (inherits(data[, i], "Date")) {
      data[, i] <- as.numeric(as.POSIXct(as.character(data[, i]), origin = "1970-01-01", tz = "GMT"))
    }
    if (inherits(data[, i], "POSIXct")) {
      data[, i] <- as.numeric(as.POSIXct(data[, i], origin = "1970-01-01", tz = "GMT"))
    }
  }
  DBI::dbWriteTable(conn = connection@dbiConnection,
                    name = tableName,
                    value = data,
                    overwrite = dropTableIfExists,
                    append = !createTable,
                    temporary = tempTable)
  invisible(NULL)
}
