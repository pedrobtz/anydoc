# Detect the Rust toolchain and generate src/Makevars from the template.
local({
  is_windows <- identical(.Platform$OS.type, "windows")
  template <- if (is_windows) "src/Makevars.win.in" else "src/Makevars.in"
  outfile <- if (is_windows) "src/Makevars.win" else "src/Makevars"

  cargo <- Sys.which("cargo")
  if (!nzchar(cargo)) {
    cargo <- file.path(path.expand("~"), ".cargo", "bin",
                       if (is_windows) "cargo.exe" else "cargo")
    if (!file.exists(cargo)) {
      stop(
        "\n-------------------------- [RUST NOT FOUND] --------------------------\n",
        "The 'cargo' command was not found on the PATH.\n",
        "Install the Rust toolchain from https://www.rust-lang.org/tools/install\n",
        "or via your package manager (e.g. 'brew install rust',\n",
        "'apt-get install cargo').\n",
        "This package needs rustc >= 1.88 (the 'anydoc' crate is edition 2024).\n",
        "----------------------------------------------------------------------",
        call. = FALSE
      )
    }
  }
  # Windows only, and only to turn backslashes into forward slashes: the recipe
  # runs under sh, and make reads a trailing backslash as a line continuation.
  #
  # Deliberately NOT normalizePath() on Unix. A rustup installation puts a
  # symlink to `rustup` at ~/.cargo/bin/cargo, and rustup dispatches on the name
  # it was invoked as - resolving the link yields `.../bin/rustup`, which would
  # then be run as `rustup build --lib ...` and fail.
  if (is_windows) {
    cargo <- normalizePath(cargo, winslash = "/", mustWork = TRUE)
  }

  # CRAN asks that the rustc version appear in the installation log, the way R
  # reports its C and Fortran compilers, and R CMD check greps for a
  # "rustc <version>" line ahead of the first crate compiled. Look next to the
  # resolved cargo when rustc is not on the PATH, which is exactly the case the
  # fallback above handles: there, Sys.which("rustc") is empty too, and skipping
  # the line would earn a check WARNING.
  message("*** cargo: ", system2(cargo, "--version", stdout = TRUE)[1L])
  rustc <- Sys.which("rustc")
  if (!nzchar(rustc)) {
    rustc <- file.path(dirname(cargo), if (is_windows) "rustc.exe" else "rustc")
  }
  if (file.exists(rustc)) {
    message("*** rustc: ", system2(rustc, "--version", stdout = TRUE)[1L])
  } else {
    # Not fatal - cargo will find its own rustc - but the missing log line costs
    # a check WARNING, so say why.
    message("*** rustc: not found next to cargo or on the PATH")
  }

  # Rust's std needs these on some platforms; harmless when redundant.
  additional <- if (is_windows) {
    ""
  } else if (Sys.info()[["sysname"]] == "Linux") {
    "-lpthread -ldl -lm"
  } else {
    ""
  }

  not_cran <- nzchar(Sys.getenv("NOT_CRAN"))
  cran_flags <- if (not_cran) "" else "--offline"

  # A CRAN-style build discards the whole ~300 MB target directory once the
  # shared object is linked; R CMD check would otherwise carry it under
  # 00_pkg_src for the rest of the run. A developer build keeps it, so an
  # incremental reload does not trigger a full recompile.
  clean_target <- if (not_cran) "$(TARGET_DIR)/release/build" else "$(TARGET_DIR)"

  txt <- readLines(template)
  txt <- gsub("@CARGO@", cargo, txt, fixed = TRUE)
  txt <- gsub("@ADDITIONAL_LIBS@", additional, txt, fixed = TRUE)
  txt <- gsub("@CRAN_FLAGS@", cran_flags, txt, fixed = TRUE)
  txt <- gsub("@CLEAN_TARGET@", clean_target, txt, fixed = TRUE)
  writeLines(txt, outfile)
  message("*** wrote ", outfile)
})
