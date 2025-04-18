test_that("aggregation functions warn once if na.rm = FALSE", {
  skip_on_cran()
  env_unbind(ns_env("rlang")$warning_freq_env, "dbplyr_check_na_rm")

  local_con(simulate_dbi())
  sql_mean <- sql_aggregate("MEAN")

  expect_warning(sql_mean("x", na.rm = TRUE), NA)
  expect_warning(sql_mean("x"), "Missing values")
  expect_warning(sql_mean("x"), NA)
})

test_that("warns informatively with unsupported function", {
  expect_snapshot(error = TRUE, sql_not_supported("cor")())
})

test_that("missing window functions create a warning", {
  local_con(simulate_dbi())
  sim_scalar <- sql_translator()
  sim_agg <- sql_translator(`+` = sql_infix("+"))
  sim_win <- sql_translator()

  expect_warning(
    sql_variant(sim_scalar, sim_agg, sim_win),
    "Translator is missing"
  )
})

test_that("duplicates throw an error", {
  expect_snapshot(error = TRUE, {
    sql_translator(round = function(x) x, round = function(y) y)
  })
})

test_that("missing aggregate functions filled in", {
  local_con(simulate_dbi())
  sim_scalar <- sql_translator()
  sim_agg <- sql_translator()
  sim_win <- sql_translator(mean = function() {})

  trans <- sql_variant(sim_scalar, sim_agg, sim_win)
  expect_error(trans$aggregate$mean(), "only available in a window")
})

test_that("output of print method for sql_variant is correct", {
  sim_trans <- sql_translator(`+` = sql_infix("+"))
  expect_snapshot(sql_variant(sim_trans, sim_trans, sim_trans))
})

test_that("win_rank() is accepted by the sql_translator", {
  expect_snapshot(
    sql_variant(
      sql_translator(
        test = win_rank("test")
      )
    )
  )
})

test_that("can translate infix expression without parentheses", {
  local_con(simulate_dbi())
  expect_equal(test_translate_sql(!!expr(2 - 1) * x), sql("(2.0 - 1.0) * `x`"))
  expect_equal(test_translate_sql(!!expr(2 / 1) * x), sql("(2.0 / 1.0) * `x`"))
  expect_equal(test_translate_sql(!!expr(2 * 1) - x), sql("(2.0 * 1.0) - `x`"))
})

test_that("unary minus works with expressions", {
  local_con(simulate_dbi())
  expect_equal(test_translate_sql(-!!expr(x+2)), sql("-(`x` + 2.0)"))
  expect_equal(test_translate_sql(--x), sql("--`x`"))
})

test_that("sql_infix generates expected output (#1345)", {
  local_con(simulate_dbi())
  x <- ident_q("x")
  y <- ident_q("y")

  expect_equal(sql_infix("-", pad = FALSE)(x, y), sql("x-y"))
  expect_equal(sql_infix("-", pad = FALSE)(NULL, y), sql("-y"))
  expect_equal(sql_infix("-")(x, y), sql("x - y"))
  expect_equal(sql_infix("-")(NULL, y), sql("- y"))
})

test_that("sql_prefix checks arguments", {
  local_con(simulate_dbi())
  sin_db <- sql_prefix("SIN", 1)

  expect_snapshot(error = TRUE, sin_db(sin(1, 2)))
  expect_snapshot(error = TRUE, sin_db(sin(a = 1)))
})

test_that("runif is translated", {
  local_con(simulate_dbi())
  expect_equal(
    test_translate_sql(runif(n())),
    sql("RANDOM()")
  )

  expect_equal(
    test_translate_sql(runif(n(), max = 2)),
    sql("RANDOM() * 2.0")
  )

  expect_equal(
    test_translate_sql(runif(n(), min = 1, max = 2)),
    sql("RANDOM() + 1.0")
  )

  expect_equal(
    test_translate_sql(runif(n(), min = 1, max = 3)),
    sql("RANDOM() * 2.0 + 1.0")
  )

  expect_snapshot(error = TRUE, {
    test_translate_sql(runif(2))
  })
})
