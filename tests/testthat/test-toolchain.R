# tools/rust-toolchain.R is configure-time code, so it is not part of the
# installed package. It is reachable from the source tree (devtools::test()) and
# from the copy R CMD check keeps under 00_pkg_src; elsewhere the test skips.
# The end-to-end check, an install under rustc 1.75, is a CI job in
# R-CMD-check.yaml.
toolchain_env <- function() {
  candidates <- c(
    test_path("..", "..", "tools", "rust-toolchain.R"),
    test_path("..", "..", "00_pkg_src", "anydoc", "tools", "rust-toolchain.R")
  )
  found <- candidates[file.exists(candidates)]
  skip_if(length(found) == 0L, "tools/rust-toolchain.R is not reachable")
  env <- new.env()
  sys.source(found[[1L]], envir = env)
  env$.root <- dirname(dirname(found[[1L]]))
  env
}

test_that("version lines from rustup, distros and nightlies are parsed", {
  tc <- toolchain_env()
  expect_identical(
    tc$rust_tool_version("rustc 1.88.0 (6b00bc388 2025-06-23)"),
    package_version("1.88.0")
  )
  expect_identical(
    tc$rust_tool_version("cargo 1.75.0 (1d8b05cdd 2023-11-20)"),
    package_version("1.75.0")
  )
  expect_identical(
    tc$rust_tool_version("rustc 1.90.0-nightly (abcdef012 2025-07-01)"),
    package_version("1.90.0")
  )
  expect_null(tc$rust_tool_version(NULL))
  expect_null(tc$rust_tool_version("something unexpected"))
})

test_that("a toolchain below the floor is refused, naming what was found", {
  tc <- toolchain_env()
  cargo <- "cargo 1.75.0 (1d8b05cdd 2023-11-20)"
  rustc <- "rustc 1.75.0 (82e1608df 2023-12-21)"
  expect_identical(tc$rust_too_old(cargo, rustc), c(cargo, rustc))

  msg <- tc$rust_too_old_message(tc$rust_too_old(cargo, rustc))
  expect_match(msg, "[RUST TOO OLD]", fixed = TRUE)
  expect_match(msg, ">= 1.88", fixed = TRUE)
  expect_match(msg, rustc, fixed = TRUE)
  expect_match(msg, "rustup", fixed = TRUE)
})

test_that("cargo 1.78-1.87 is refused too, though it can read the lock file", {
  tc <- toolchain_env()
  expect_length(tc$rust_too_old("cargo 1.87.0 (x 2025-05-06)", NULL), 1L)
})

test_that("the floor itself and anything newer is accepted", {
  tc <- toolchain_env()
  expect_length(
    tc$rust_too_old(
      "cargo 1.88.0 (x 2025-06-23)",
      "rustc 1.88.0 (y 2025-06-23)"
    ),
    0L
  )
  expect_length(
    tc$rust_too_old(
      "cargo 1.97.1 (x 2026-08-01)",
      "rustc 1.97.1 (y 2026-08-01)"
    ),
    0L
  )
  # An unreadable version is left for cargo to judge, not refused.
  expect_length(tc$rust_too_old("cargo ???", NULL), 0L)
})

test_that("the floor agrees with DESCRIPTION and Cargo.toml", {
  tc <- toolchain_env()
  root <- tc$.root
  desc <- read.dcf(
    file.path(root, "DESCRIPTION"),
    fields = "SystemRequirements"
  )
  expect_match(
    desc[[1L]],
    paste0("rustc (>= ", tc$rust_floor, ")"),
    fixed = TRUE
  )

  cargo_toml <- file.path(root, "src", "rust", "Cargo.toml")
  skip_if_not(file.exists(cargo_toml))
  expect_true(any(
    readLines(cargo_toml) == sprintf('rust-version = "%s"', tc$rust_floor)
  ))
})
