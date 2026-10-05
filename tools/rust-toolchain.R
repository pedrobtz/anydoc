# Rust toolchain floor, and the comparison tools/config.R makes against it.
#
# Kept in its own file, free of side effects, so the test suite can source it
# and feed it canned `--version` lines (tests/testthat/test-toolchain.R).
#
# Why configure checks this itself rather than leaving it to cargo: Cargo.lock
# is lockfile version 4, which cargo < 1.78 cannot parse. An old cargo therefore
# dies with "lock file version `4` was found, but this version of Cargo does not
# understand this lock file" before it ever reads `rust-version`, so the user is
# never told that 1.88 is needed - and on the CRAN path only after the vendor
# archive has been downloaded. Ubuntu 24.04 LTS ships 1.75, exactly this case.
#
# Keep in step with SystemRequirements in DESCRIPTION and `rust-version` in
# src/rust/Cargo.toml.
rust_floor <- "1.88"

# The numeric version in the first line of `rustc --version` / `cargo
# --version`, e.g. "rustc 1.88.0 (6b00bc388 2025-06-23)" or
# "cargo 1.90.0-nightly (...)". NULL when the line is absent or unrecognised:
# an unparseable line is not evidence of an old toolchain, so the caller lets
# cargo decide rather than refusing a toolchain that may well work.
rust_tool_version <- function(line) {
  if (is.null(line) || !length(line) || is.na(line[[1L]])) {
    return(NULL)
  }
  m <- regmatches(
    line[[1L]],
    regexec(
      "^(rustc|cargo)[[:space:]]+([0-9]+\\.[0-9]+(\\.[0-9]+)?)",
      line[[1L]]
    )
  )[[1L]]
  if (length(m) < 3L) {
    return(NULL)
  }
  package_version(m[[3L]])
}

# The `--version` lines that report a version below `floor`; character(0) when
# the toolchain is new enough (or its version cannot be read).
rust_too_old <- function(cargo_line, rustc_line, floor = rust_floor) {
  lines <- c(cargo_line, rustc_line)
  old <- vapply(
    lines,
    function(line) {
      v <- rust_tool_version(line)
      !is.null(v) && v < package_version(floor)
    },
    logical(1),
    USE.NAMES = FALSE
  )
  lines[old]
}

# The configure-time error for a toolchain below the floor.
rust_too_old_message <- function(old, floor = rust_floor) {
  paste0(
    "\n------------------------- [RUST TOO OLD] -----------------------------\n",
    "This package needs rustc and cargo >= ",
    floor,
    " (the 'anydoc' crate is edition 2024).\n",
    "Found:\n",
    paste0("  ", old, collapse = "\n"),
    "\n",
    "Distribution packages are often older (Ubuntu 24.04 LTS ships 1.75).\n",
    "Install or update the toolchain with rustup\n",
    "(https://www.rust-lang.org/tools/install), then run\n",
    "  rustup update stable && rustup default stable\n",
    "----------------------------------------------------------------------"
  )
}
