#' Backend: SQL server
#'
#' @description
#' See `vignette("translation-function")` and `vignette("translation-verb")` for
#' details of overall translation technology. Key differences for this backend
#' are:
#'
#' - `SELECT` uses `TOP` not `LIMIT`
#' - Automatically prefixes `#` to create temporary tables. Add the prefix
#'   yourself to avoid the message.
#' - String basics: `paste()`, `substr()`, `nchar()`
#' - Custom types for `as.*` functions
#' - Lubridate extraction functions, `year()`, `month()`, `day()` etc
#' - Semi-automated bit <-> boolean translation (see below)
#'
#' Use `simulate_mssql()` with `lazy_frame()` to see simulated SQL without
#' converting to live access database.
#'
#' @section Bit vs boolean:
#' SQL server uses two incompatible types to represent `TRUE` and `FALSE`
#' values:
#'
#' * The `BOOLEAN` type is the result of logical comparisons (e.g. `x > y`)
#'   and can be used `WHERE` but not to create new columns in `SELECT`.
#'   <https://learn.microsoft.com/en-us/sql/t-sql/language-elements/comparison-operators-transact-sql>
#'
#' * The `BIT` type is a special type of numeric column used to store
#'   `TRUE` and `FALSE` values, but can't be used in `WHERE` clauses.
#'   <https://learn.microsoft.com/en-us/sql/t-sql/data-types/bit-transact-sql?view=sql-server-ver15>
#'
#' dbplyr does its best to automatically create the correct type when needed,
#' but can't do it 100% correctly because it does not have a full type
#' inference system. This means that you many need to manually do conversions
#' from time to time.
#'
#' * To convert from bit to boolean use `x == 1`
#' * To convert from boolean to bit use `as.logical(if(x, 0, 1))`
#'
#' @param version Version of MS SQL to simulate. Currently only, difference is
#'   that 15.0 and above will use `TRY_CAST()` instead of `CAST()`.
#' @name backend-mssql
#' @aliases NULL
#' @examples
#' library(dplyr, warn.conflicts = FALSE)
#'
#' lf <- lazy_frame(a = TRUE, b = 1, c = 2, d = "z", con = simulate_mssql())
#' lf %>% head()
#' lf %>% transmute(x = paste(b, c, d))
#'
#' # Can use boolean as is:
#' lf %>% filter(c > d)
#' # Need to convert from boolean to bit:
#' lf %>% transmute(x = c > d)
#' # Can use boolean as is:
#' lf %>% transmute(x = ifelse(c > d, "c", "d"))
NULL

#' @include verb-copy-to.R
NULL

#' @export
#' @rdname backend-mssql
simulate_mssql <- function(version = "15.0") {
  simulate_dbi("Microsoft SQL Server",
    version = numeric_version(version)
  )
}

#' @export
`dbplyr_edition.Microsoft SQL Server` <- function(con) {
  2L
}

#' @export
`sql_query_select.Microsoft SQL Server` <- function(con,
                                                    select,
                                                    from,
                                                    where = NULL,
                                                    group_by = NULL,
                                                    having = NULL,
                                                    window = NULL,
                                                    order_by = NULL,
                                                    limit = NULL,
                                                    distinct = FALSE,
                                                    ...,
                                                    subquery = FALSE,
                                                    lvl = 0) {
  sql_select_clauses(con,
    select    = sql_clause_select(con, select, distinct, top = limit),
    from      = sql_clause_from(from),
    where     = sql_clause_where(where),
    group_by  = sql_clause_group_by(group_by),
    having    = sql_clause_having(having),
    window    = sql_clause_window(window),
    order_by  = sql_clause_order_by(order_by, subquery, limit),
    lvl       = lvl
  )
}

#' @export
`sql_query_insert.Microsoft SQL Server` <- function(con,
                                                    table,
                                                    from,
                                                    insert_cols,
                                                    by,
                                                    ...,
                                                    conflict = c("error", "ignore"),
                                                    returning_cols = NULL,
                                                    method = NULL) {
  # https://stackoverflow.com/questions/25969/insert-into-values-select-from
  conflict <- rows_check_conflict(conflict)

  check_character(returning_cols, allow_null = TRUE)

  check_string(method, allow_null = TRUE)
  method <- method %||% "where_not_exists"
  arg_match(method, "where_not_exists", error_arg = "method")

  parts <- rows_insert_prep(con, table, from, insert_cols, by, lvl = 0)

  clauses <- list2(
    parts$insert_clause,
    sql_returning_cols(con, returning_cols, "INSERTED"),
    sql_clause_select(con, sql("*")),
    sql_clause_from(parts$from),
    !!!parts$conflict_clauses
  )

  sql_format_clauses(clauses, lvl = 0, con)
}

#' @export
`sql_query_append.Microsoft SQL Server` <- function(con,
                                                    table,
                                                    from,
                                                    insert_cols,
                                                    ...,
                                                    returning_cols = NULL) {
  parts <- rows_prep(con, table, from, by = list(), lvl = 0)
  insert_cols <- escape(ident(insert_cols), collapse = ", ", parens = TRUE, con = con)

  clauses <- list2(
    sql_clause_insert(con, insert_cols, table),
    sql_returning_cols(con, returning_cols, "INSERTED"),
    sql_clause_select(con, sql("*")),
    sql_clause_from(parts$from)
  )

  sql_format_clauses(clauses, lvl = 0, con)
}

#' @export
`sql_query_update_from.Microsoft SQL Server` <- function(con,
                                                         table,
                                                         from,
                                                         by,
                                                         update_values,
                                                         ...,
                                                         returning_cols = NULL) {
  # https://stackoverflow.com/a/2334741/946850
  parts <- rows_prep(con, table, from, by, lvl = 0)
  update_cols <- sql_escape_ident(con, names(update_values))

  clauses <- list(
    sql_clause_update(table),
    sql_clause_set(update_cols, update_values),
    sql_returning_cols(con, returning_cols, "INSERTED"),
    sql_clause_from(table),
    sql_clause("INNER JOIN", parts$from),
    sql_clause_on(parts$where, lvl = 1)
  )
  sql_format_clauses(clauses, lvl = 0, con)
}

#' @export
`sql_query_upsert.Microsoft SQL Server` <- function(con,
                                                    table,
                                                    from,
                                                    by,
                                                    update_cols,
                                                    ...,
                                                    returning_cols = NULL,
                                                    method = NULL) {
  check_string(method, allow_null = TRUE)
  method <- method %||% "merge"
  arg_match(method, "merge", error_arg = "method")

  parts <- rows_prep(con, table, from, by, lvl = 0)

  update_cols_esc <- sql(sql_escape_ident(con, update_cols))
  update_values <- sql_table_prefix(con, update_cols, "...y")
  update_clause <- sql(paste0(update_cols_esc, " = ", update_values))

  insert_cols <- c(by, update_cols)
  insert_cols_esc <- sql(sql_escape_ident(con, insert_cols))
  insert_cols_qual <- sql_table_prefix(con, insert_cols, "...y")

  clauses <- list(
    sql_clause("MERGE INTO", table),
    sql_clause("USING", parts$from),
    sql_clause_on(parts$where, lvl = 1),
    sql("WHEN MATCHED THEN"),
    sql_clause("UPDATE SET", update_clause, lvl = 1),
    sql("WHEN NOT MATCHED THEN"),
    sql_clause_insert(con, insert_cols_esc, lvl = 1),
    sql_clause("VALUES", insert_cols_qual, parens = TRUE, lvl = 1),
    sql_returning_cols(con, returning_cols, "INSERTED"),
    sql(";")
  )
  sql_format_clauses(clauses, lvl = 0, con)
}

#' @export
`sql_query_delete.Microsoft SQL Server` <- function(con,
                                                    table,
                                                    from,
                                                    by,
                                                    ...,
                                                    returning_cols = NULL) {
  parts <- rows_prep(con, table, from, by, lvl = 0)

  clauses <- list2(
    sql_clause("DELETE FROM", table),
    sql_returning_cols(con, returning_cols, table = "DELETED"),
    !!!sql_clause_where_exists(parts$from, parts$where, not = FALSE)
  )
  sql_format_clauses(clauses, lvl = 0, con)
}

#' @export
`sql_translation.Microsoft SQL Server` <- function(con) {
  mssql_scalar <-
    sql_translator(.parent = base_odbc_scalar,

      `!`           = function(x) {
                        if (mssql_needs_bit()) {
                          x <- with_mssql_bool(x)
                          sql_expr(~ !!mssql_as_bit(x))
                        } else {
                          sql_expr(NOT(!!x))
                        }
                      },

      `!=`           = mssql_infix_comparison("!="),
      `==`           = mssql_infix_comparison("="),
      `<`            = mssql_infix_comparison("<"),
      `<=`           = mssql_infix_comparison("<="),
      `>`            = mssql_infix_comparison(">"),
      `>=`           = mssql_infix_comparison(">="),

      `&`            = mssql_infix_boolean("&", "%AND%"),
      `&&`           = mssql_infix_boolean("&", "%AND%"),
      `|`            = mssql_infix_boolean("|", "%OR%"),
      `||`           = mssql_infix_boolean("|", "%OR%"),

      `[` = function(x, i) {
        i <- with_mssql_bool(i)
        glue_sql2(sql_current_con(), "CASE WHEN ({i}) THEN ({x}) END")
      },

      bitwShiftL     = sql_not_supported("bitwShiftL"),
      bitwShiftR     = sql_not_supported("bitwShiftR"),

      `if`           = function(condition, true, false = NULL, missing = NULL) {
        mssql_sql_if(enquo(condition), enquo(true), enquo(false), enquo(missing))
      },
      if_else        = function(condition, true, false, missing = NULL) {
        mssql_sql_if(enquo(condition), enquo(true), enquo(false), enquo(missing))
      },
      ifelse         = function(test, yes, no) {
        mssql_sql_if(enquo(test), enquo(yes), enquo(no))
      },
      case_when      = mssql_case_when,
      between        = function(x, left, right) {
        context <- sql_current_context()
        if (context$clause == "WHERE") {
          sql_expr(!!x %BETWEEN% !!left %AND% !!right)
        } else {
          sql_expr(IIF(!!x %BETWEEN% !!left %AND% !!right, 1L, 0L))
        }
      },

      as.logical    = sql_cast("BIT"),

      as.Date       = sql_cast("DATE"),
      as.numeric    = sql_cast("FLOAT"),
      as.double     = sql_cast("FLOAT"),
      as.character  = sql_cast("VARCHAR(MAX)"),
      log           = sql_prefix("LOG"),
      atan2         = sql_prefix("ATN2"),
      ceil          = sql_prefix("CEILING"),
      ceiling       = sql_prefix("CEILING"),

      # https://dba.stackexchange.com/questions/187090
      pmin          = sql_not_supported("pmin"),
      pmax          = sql_not_supported("pmax"),

      is.null       = mssql_is_null,
      is.na         = mssql_is_null,

      runif = function(n = n(), min = 0, max = 1) {
        sql_runif(RAND(), n = {{ n }}, min = min, max = max)
      },

      # string functions ------------------------------------------------
      nchar = sql_prefix("LEN"),
      paste = sql_paste_infix(" ", "+", function(x) sql_expr(cast(!!x %as% text))),
      paste0 = sql_paste_infix("", "+", function(x) sql_expr(cast(!!x %as% text))),
      substr = sql_substr("SUBSTRING"),
      substring = sql_substr("SUBSTRING"),

      # stringr functions
      str_length = sql_prefix("LEN"),
      str_c = sql_paste_infix("", "+", function(x) sql_expr(cast(!!x %as% text))),
      # no built in function: https://stackoverflow.com/questions/230138
      str_to_title = sql_not_supported("str_to_title"),
      # https://docs.microsoft.com/en-us/sql/t-sql/functions/substring-transact-sql?view=sql-server-ver15
      str_sub = sql_str_sub("SUBSTRING", "LEN", optional_length = FALSE),

      # lubridate ---------------------------------------------------------------
      # https://en.wikibooks.org/wiki/SQL_Dialects_Reference/Functions_and_expressions/Date_and_time_functions
      as_date = sql_cast("DATE"),

      # Using DATETIME2 as it complies with ANSI and ISO.
      # MS recommends DATETIME2 for new work:
      # https://docs.microsoft.com/en-us/sql/t-sql/data-types/datetime-transact-sql?view=sql-server-2017
      as_datetime = sql_cast("DATETIME2"),

      today = function() sql_expr(CAST(SYSDATETIME() %AS% DATE)),

      # https://docs.microsoft.com/en-us/sql/t-sql/functions/datepart-transact-sql?view=sql-server-2017
      year = function(x) sql_expr(DATEPART(YEAR, !!x)),
      day = function(x) sql_expr(DATEPART(DAY, !!x)),
      mday = function(x) sql_expr(DATEPART(DAY, !!x)),
      yday = function(x) sql_expr(DATEPART(DAYOFYEAR, !!x)),
      hour = function(x) sql_expr(DATEPART(HOUR, !!x)),
      minute = function(x) sql_expr(DATEPART(MINUTE, !!x)),
      second = function(x) sql_expr(DATEPART(SECOND, !!x)),

      month = function(x, label = FALSE, abbr = TRUE) {
        check_bool(label)
        if (!label) {
          sql_expr(DATEPART(MONTH, !!x))
        } else {
          check_unsupported_arg(abbr, FALSE, backend = "SQL Server")
          sql_expr(DATENAME(MONTH, !!x))
        }
      },

      quarter = function(x, with_year = FALSE, fiscal_start = 1) {
        check_bool(with_year)
        check_unsupported_arg(fiscal_start, 1, backend = "SQL Server")

        if (with_year) {
          sql_expr((DATENAME(YEAR, !!x) + '.' + DATENAME(QUARTER, !!x)))
        } else {
          sql_expr(DATEPART(QUARTER, !!x))
        }
      },

      # clock ---------------------------------------------------------------
      add_days = function(x, n, ...) {
        check_dots_empty()
        sql_expr(DATEADD(DAY, !!n, !!x))
      },
      add_years = function(x, n, ...) {
        check_dots_empty()
        sql_expr(DATEADD(YEAR, !!n, !!x))
      },
      date_build = function(year, month = 1L, day = 1L, ..., invalid = NULL) {
        check_unsupported_arg(invalid, allow_null = TRUE)
        sql_expr(DATEFROMPARTS(!!year, !!month, !!day))
      },
      get_year = function(x) {
        sql_expr(DATEPART(YEAR, !!x))
      },
      get_month = function(x) {
        sql_expr(DATEPART(MONTH, !!x))
      },
      get_day = function(x) {
        sql_expr(DATEPART(DAY, !!x))
      },
      date_count_between = function(start, end, precision, ..., n = 1L){
        check_dots_empty()
        check_unsupported_arg(precision, allowed = "day")
        check_unsupported_arg(n, allowed = 1L)

        sql_expr(DATEDIFF(DAY, !!start, !!end))
      },

      difftime = function(time1, time2, tz, units = "days") {
        check_unsupported_arg(tz)
        check_unsupported_arg(units, allowed = "days")

        sql_expr(DATEDIFF(DAY, !!time2, !!time1))
      }
    )

  if (mssql_version(con) >= "11.0") { # MSSQL 2012
    mssql_scalar <- sql_translator(
      .parent = mssql_scalar,
      as.logical = sql_try_cast("BIT"),
      as.Date = sql_try_cast("DATE"),
      as.POSIXct = sql_try_cast("DATETIME2"),
      as.numeric = sql_try_cast("FLOAT"),
      as.double = sql_try_cast("FLOAT"),

      # In SQL server, CAST (even with TRY) of INTEGER and BIGINT appears
      # fill entire columns with NULL if parsing single value fails:
      # https://gist.github.com/DavidPatShuiFong/7b47a9804a497b605e477f1bf6c38b37
      # So we parse to NUMERIC (which doesn't have this problem), then to the
      # target type
      as.integer = function(x) {
        sql_expr(try_cast(try_cast(!!x %as% NUMERIC) %as% INT))
      },
      as.integer64 = function(x) {
        sql_expr(try_cast(try_cast(!!x %as% NUMERIC(38L, 0L)) %as% BIGINT))
      },
      as.character = sql_try_cast("VARCHAR(MAX)"),
      as_date = sql_try_cast("DATE"),
      as_datetime = sql_try_cast("DATETIME2")
    )
  }

  sql_variant(
    mssql_scalar,
    sql_translator(.parent = base_odbc_agg,
      sd            = sql_aggregate("STDEV", "sd"),
      var           = sql_aggregate("VAR", "var"),
      str_flatten = function(x, collapse = "") sql_expr(string_agg(!!x, !!collapse)),

      median = sql_agg_not_supported("median", "SQL Server"),
      quantile = sql_agg_not_supported("quantile", "SQL Server"),
      all = mssql_bit_int_bit(sql_aggregate("MIN")),
      any = mssql_bit_int_bit(sql_aggregate("MAX"))
    ),
    sql_translator(.parent = base_odbc_win,
      sd            = win_aggregate("STDEV"),
      var           = win_aggregate("VAR"),
      str_flatten = function(x, collapse = "") {
        win_over(
          sql_expr(string_agg(!!x, !!collapse)),
          partition = win_current_group(),
          order = win_current_order()
        )
      },

      # percentile_cont needs `OVER()` in mssql
      # https://docs.microsoft.com/en-us/sql/t-sql/functions/percentile-cont-transact-sql?view=sql-server-ver15
      median = sql_median("PERCENTILE_CONT", "ordered", window = TRUE),
      quantile = sql_quantile("PERCENTILE_CONT", "ordered", window = TRUE),
      first = function(x, order_by = NULL, na_rm = FALSE) {
        sql_nth(
          x = x,
          n = 1L,
          order_by = order_by,
          na_rm = na_rm,
          ignore_nulls = "outside"
        )
      },
      last = function(x, order_by = NULL, na_rm = FALSE) {
        sql_nth(
          x = x,
          n = Inf,
          order_by = order_by,
          na_rm = na_rm,
          ignore_nulls = "outside"
        )
      },
      nth = function(x, n, order_by = NULL, na_rm = FALSE) {
        sql_nth(
          x = x,
          n = n,
          order_by = order_by,
          na_rm = na_rm,
          ignore_nulls = "outside"
        )
      },
      all = mssql_bit_int_bit(win_aggregate("MIN")),
      any = mssql_bit_int_bit(win_aggregate("MAX")),
      row_number = win_rank("ROW_NUMBER", empty_order = TRUE),

      n_distinct = function(x) {
        cli_abort(
          "No translation available in `mutate()`/`filter()` for SQL server."
        )
      }
    )

  )}

mssql_version <- function(con) {
  if (inherits(con, "TestConnection")) {
    attr(con, "version")
  } else {
    numeric_version(DBI::dbGetInfo(con)$db.version) # nocov
  }
}

#' @export
`sql_escape_raw.Microsoft SQL Server` <- function(con, x) {
  if (is.null(x)) {
    "NULL"
  } else {
    # SQL Server binary constants should be prefixed with 0x
    # https://docs.microsoft.com/en-us/sql/t-sql/data-types/constants-transact-sql?view=sql-server-ver15#binary-constants
    paste0(c("0x", format(x)), collapse = "")
  }
}

#' @export
`sql_table_analyze.Microsoft SQL Server` <- function(con, table, ...) {
  # https://docs.microsoft.com/en-us/sql/t-sql/statements/update-statistics-transact-sql
  glue_sql2(con, "UPDATE STATISTICS {.tbl table}")
}

# SQL server does not use CREATE TEMPORARY TABLE and instead prefixes
# temporary table names with #
# <https://docs.microsoft.com/en-us/previous-versions/sql/sql-server-2008-r2/ms177399%28v%3dsql.105%29#temporary-tables>
#' @export
`db_table_temporary.Microsoft SQL Server` <- function(con, table, temporary, ...) {
  list(
    table = add_temporary_prefix(con, table, temporary = temporary),
    temporary = FALSE
  )
}


#' @export
`sql_query_save.Microsoft SQL Server` <- function(con,
                                                  sql,
                                                  name,
                                                  temporary = TRUE,
                                                  ...) {

  # https://stackoverflow.com/q/16683758/946850
  glue_sql2(con, "SELECT * INTO {.tbl name} FROM (\n  {sql}\n) AS temp")
}

#' @export
`sql_values_subquery.Microsoft SQL Server` <- sql_values_subquery_column_alias

#' @export
`sql_returning_cols.Microsoft SQL Server` <- function(con, cols, table, ...) {
  arg_match(table, values = c("DELETED", "INSERTED"))
  returning_cols <- sql_named_cols(con, cols, table = table)

  sql_clause("OUTPUT", returning_cols)
}

# Bit vs boolean ----------------------------------------------------------

mssql_needs_bit <- function() {
  context <- sql_current_context()
  identical(context$clause, "SELECT") || identical(context$clause, "ORDER")
}

with_mssql_bool <- function(code) {
  local_context(list(clause = ""))
  code
}

mssql_as_bit <- function(x) {
  if (mssql_needs_bit()) {
    sql_expr(cast(iif(!!x, 1L, 0L) %as% BIT))
  } else {
    x
  }
}

mssql_is_null <- function(x) {
  mssql_as_bit(sql_is_null({{x}}))
}

mssql_infix_comparison <- function(f) {
  check_string(f)
  f <- toupper(f)
  function(x, y) {
    mssql_as_bit(glue_sql2(sql_current_con(), "{.val x} {f} {.val y}"))
  }
}

mssql_infix_boolean <- function(if_bit, if_bool) {
  force(if_bit)
  force(if_bool)

  function(x, y) {
    if (mssql_needs_bit()) {
      x <- with_mssql_bool(x)
      y <- with_mssql_bool(y)
      mssql_as_bit(sql_call2(if_bool, x, y))
    } else {
      sql_call2(if_bool, x, y)
    }
  }
}

mssql_sql_if <- function(cond, if_true, if_false = NULL, missing = NULL) {
  cond_sql <- with_mssql_bool(eval_tidy(cond))
  if (is_null(missing) || quo_is_null(missing)) {
    if_true_sql <- escape(eval_tidy(if_true), con = sql_current_con())
    if (is_null(if_false) || quo_is_null(if_false)) {
      if_false_sql <- NULL
    } else {
      if_false_sql <- escape(eval_tidy(if_false), con = sql_current_con())
    }
    sql_expr(IIF(!!cond_sql, !!if_true_sql, !!if_false_sql))
  } else {
    sql_if(cond, if_true, if_false, missing)
  }
}

mssql_case_when <- function(...) {
  with_mssql_bool(sql_case_when(...))
}

mssql_bit_int_bit <- function(f) {
  # bit fields must be cast to numeric before aggregating (e.g. min/max).
  function(x, na.rm = FALSE) {
    f_wrapped <- purrr::compose(
      sql_cast("BIT"),
      purrr::partial(f, na.rm = na.rm),
      sql_cast("INT")
    )

    f_wrapped(x)
  }
}

#' @export
`sql_escape_logical.Microsoft SQL Server` <- function(con, x) {
  dplyr::if_else(x, "1", "0", "NULL")
}

#' @export
`db_sql_render.Microsoft SQL Server` <- function(con, sql, ..., cte = FALSE, use_star = TRUE) {
  # Post-process WHERE to cast logicals from BIT to BOOLEAN
  sql$lazy_query <- purrr::modify_tree(
    sql$lazy_query,
    is_node = function(x) inherits(x, "lazy_query"),
    post = mssql_update_where_clause
  )

  NextMethod()
}

mssql_update_where_clause <- function(qry) {
  if (!has_name(qry, "where")) {
    return(qry)
  }

  qry$where <- lapply(
    qry$where,
    function(x) set_expr(x, bit_to_boolean(get_expr(x)))
  )
  qry
}

bit_to_boolean <- function(x_expr) {
  if (is_atomic(x_expr) || is_symbol(x_expr)) {
    expr(cast(!!x_expr %AS% BIT) == 1L)
  } else if (is_call(x_expr, c("|", "&", "||", "&&", "!", "("))) {
    idx <- seq2(2, length(x_expr))
    x_expr[idx] <- lapply(x_expr[idx], bit_to_boolean)
    x_expr
  } else {
    x_expr
  }
}

utils::globalVariables(c("BIT", "CAST", "%AS%", "%is%", "convert", "DATE", "DATEADD", "DATEFROMPARTS", "DATEDIFF", "DATENAME", "DATEPART", "IIF", "NOT", "SUBSTRING", "LTRIM", "RTRIM", "CHARINDEX", "SYSDATETIME", "SECOND", "MINUTE", "HOUR", "DAY", "DAYOFWEEK", "DAYOFYEAR", "MONTH", "QUARTER", "YEAR", "BIGINT", "INT", "%AND%", "%BETWEEN%"))
