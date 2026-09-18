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

  # First line of `<tool> --version`, or NULL when the tool cannot run at all.
  # A rustup proxy with no default toolchain installed exits non-zero and
  # prints nothing useful, which used to surface as "*** cargo: NA" - a log
  # line that looks like a version and is not.
  version_line <- function(cmd, args = "--version") {
    out <- tryCatch(
      suppressWarnings(system2(cmd, args, stdout = TRUE, stderr = TRUE)),
      error = function(e) NULL
    )
    status <- attr(out, "status")
    if (is.null(out) || !length(out) || (!is.null(status) && status != 0L)) {
      return(NULL)
    }
    line <- out[[1L]]
    if (is.na(line) || !nzchar(line)) NULL else line
  }

  # CRAN asks that the rustc version appear in the installation log, the way R
  # reports its C and Fortran compilers, and R CMD check greps for a
  # "rustc <version>" line ahead of the first crate compiled. Look next to the
  # resolved cargo when rustc is not on the PATH, which is exactly the case the
  # fallback above handles: there, Sys.which("rustc") is empty too, and skipping
  # the line would earn a check WARNING.
  cargo_version <- version_line(cargo)
  if (is.null(cargo_version)) {
    stop(
      "\n------------------------ [RUST NOT USABLE] ---------------------------\n",
      "Found cargo at:\n  ", cargo, "\n",
      "but '<cargo> --version' did not run successfully.\n",
      "If this is a rustup proxy, no default toolchain is selected. Fix it with\n",
      "  rustup default stable\n",
      "----------------------------------------------------------------------",
      call. = FALSE
    )
  }
  message("*** cargo: ", cargo_version)

  rustc <- Sys.which("rustc")
  if (!nzchar(rustc)) {
    rustc <- file.path(dirname(cargo), if (is_windows) "rustc.exe" else "rustc")
  }
  rustc_version <- if (file.exists(rustc)) version_line(rustc) else NULL
  if (!is.null(rustc_version)) {
    message("*** rustc: ", rustc_version)
  } else {
    # Not fatal - cargo will find its own rustc - but the missing log line costs
    # a check WARNING, so say why.
    message("*** rustc: not found next to cargo or on the PATH")
  }

  # Windows needs an explicit --target: Rtools links with the GNU toolchain,
  # while rustup on Windows defaults to an MSVC host, and an MSVC staticlib
  # cannot be linked by Rtools. Unix builds for the host and passes no target,
  # so cargo writes to target/release rather than target/<triple>/release.
  target <- ""
  if (is_windows) {
    target <- if (identical(R.version$arch, "aarch64")) {
      "aarch64-pc-windows-gnullvm"
    } else {
      "x86_64-pc-windows-gnu"
    }
    message("*** target: ", target)
    # Guidance beats cargo's "can't find crate for `std`" when the target's
    # standard library was never installed. Only a warning: a non-rustup
    # toolchain may lay its sysroot out differently and still work.
    libdir <- suppressWarnings(tryCatch(
      system2(rustc, c("--print", "target-libdir", paste0("--target=", target)),
              stdout = TRUE, stderr = FALSE),
      error = function(e) character()
    ))
    if (length(libdir) && !is.na(libdir[[1L]]) && !dir.exists(libdir[[1L]])) {
      message(
        "*** WARNING: the standard library for ", target, " does not appear\n",
        "***          to be installed. If the build fails to find `std`, run:\n",
        "***            rustup target add ", target
      )
    }
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
  #
  # $(LIBDIR), not $(TARGET_DIR)/release: on Windows the profile directory sits
  # under the target triple, so the literal path would name a directory cargo
  # never creates and the developer build would silently keep its stale
  # build scripts.
  clean_target <- if (not_cran) "$(LIBDIR)/build" else "$(TARGET_DIR)"

  txt <- readLines(template)
  txt <- gsub("@CARGO@", cargo, txt, fixed = TRUE)
  txt <- gsub("@TARGET@", target, txt, fixed = TRUE)
  txt <- gsub("@ADDITIONAL_LIBS@", additional, txt, fixed = TRUE)
  txt <- gsub("@CRAN_FLAGS@", cran_flags, txt, fixed = TRUE)
  txt <- gsub("@CLEAN_TARGET@", clean_target, txt, fixed = TRUE)
  writeLines(txt, outfile)
  message("*** wrote ", outfile)
})
