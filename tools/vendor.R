# Acquire the vendored Rust crate archive before cargo runs.
#
# The archive is not shipped inside the source tarball: the vendored tree is
# ~11 MB compressed, well past CRAN's size guidance. It is hosted per-version as
# a GitHub Release asset and fetched here, then unpacked by src/Makevars for an
# offline cargo build.
#
# The expected SHA256 lives in tools/vendor.sha256, *committed to the package*.
# CRAN requires the checksum to be embedded in the source package, and a digest
# downloaded from the same host as the archive would in any case verify nothing
# about that host.
#
# Decision tree:
#   1. ANYDOC_VENDOR_TARBALL set -> use that local archive (not verified; it is
#      a developer escape hatch, and the developer chose the file).
#   2. src/rust/vendor/ already extracted -> nothing to do.
#   3. src/rust/vendor.tar.xz already present -> nothing to do.
#   4. NOT_CRAN set -> skip the fetch; cargo resolves crates online.
#   5. Otherwise download and verify against the committed digest.
#
# Nothing is written outside the source tree or the session tempdir.

local({
  pkg_root <- getwd()
  vendor_xz <- file.path(pkg_root, "src", "rust", "vendor.tar.xz")
  vendor_dir <- file.path(pkg_root, "src", "rust", "vendor")
  sha_file <- file.path(pkg_root, "tools", "vendor.sha256")

  desc <- read.dcf(file.path(pkg_root, "DESCRIPTION"))
  pkg_version <- unname(desc[, "Version"])

  copy <- function(src, dest) {
    if (!file.copy(src, dest, overwrite = TRUE)) {
      stop(sprintf("Failed to copy '%s' to '%s'.", src, dest), call. = FALSE)
    }
  }

  override <- Sys.getenv("ANYDOC_VENDOR_TARBALL")
  if (nzchar(override)) {
    if (!file.exists(override)) {
      stop("ANYDOC_VENDOR_TARBALL points at '", override,
           "' which does not exist.", call. = FALSE)
    }
    message("Using vendor archive from ANYDOC_VENDOR_TARBALL: ", override)
    copy(override, vendor_xz)
    return(invisible())
  }

  if (dir.exists(vendor_dir)) {
    message("Vendor directory already present; skipping fetch.")
    return(invisible())
  }
  if (file.exists(vendor_xz)) {
    message("Vendor archive already present; skipping fetch.")
    return(invisible())
  }
  if (nzchar(Sys.getenv("NOT_CRAN"))) {
    message("NOT_CRAN is set; skipping vendor fetch. cargo will use the network.")
    return(invisible())
  }

  # The digest is what makes the download trustworthy, so a missing or
  # placeholder one is a hard error rather than a skipped check.
  if (!file.exists(sha_file)) {
    stop("Missing ", sha_file, ", which must hold the expected SHA256 of ",
         "vendor.tar.xz.", call. = FALSE)
  }
  expected <- sub("\\s.*$", "", readLines(sha_file, warn = FALSE)[[1L]])
  if (!grepl("^[0-9a-fA-F]{64}$", expected)) {
    stop("tools/vendor.sha256 does not contain a 64-character hex SHA256.\n",
         "For a release, build the archive with tools/make-vendor.sh and commit ",
         "the digest it prints.\nTo build without it, set one of:\n",
         "  ANYDOC_VENDOR_TARBALL=/path/to/vendor.tar.xz\n",
         "  NOT_CRAN=true\n", call. = FALSE)
  }

  default_base <- sprintf(
    "https://github.com/pedrobtz/anydoc/releases/download/v%s", pkg_version
  )
  archive_url <- paste0(Sys.getenv("ANYDOC_VENDOR_URL", unset = default_base),
                        "/vendor.tar.xz")

  # R's default download timeout is 60 seconds and this archive is ~11 MB, so
  # finishing inside the default needs a sustained 180 KB/s. Below that,
  # download.file() aborts part-way and the install fails on a perfectly good
  # asset - an intermittent, unreproducible failure on CRAN's rebuild farm.
  old_timeout <- options(timeout = max(600, getOption("timeout")))
  on.exit(options(old_timeout), add = TRUE)

  archive_tmp <- tempfile(fileext = ".tar.xz")
  on.exit(unlink(archive_tmp), add = TRUE)

  bypass <- paste0(
    "\n\nTo bypass the network fetch, set one of:\n",
    "  ANYDOC_VENDOR_TARBALL=/path/to/vendor.tar.xz\n",
    "  ANYDOC_VENDOR_URL=https://example/v", pkg_version, "\n",
    "  NOT_CRAN=true\n"
  )

  # Transient network failures are the expected case for a fetch that CRAN
  # itself repeats on every rebuild, so retry before giving up.
  attempts <- 3L
  for (attempt in seq_len(attempts)) {
    message("Downloading vendor archive from ", archive_url,
            if (attempt > 1L) sprintf(" (attempt %d of %d)", attempt, attempts))
    status <- tryCatch(
      utils::download.file(archive_url, archive_tmp, mode = "wb", quiet = FALSE),
      # Kept as a string rather than re-signalled, so the retry loop owns the
      # decision about when a failure becomes fatal.
      error = function(e) conditionMessage(e)
    )
    if (identical(status, 0L) && file.exists(archive_tmp) &&
        file.size(archive_tmp) > 0L) {
      break
    }
    unlink(archive_tmp)
    if (attempt == attempts) {
      stop("Failed to download the vendor archive from\n  ", archive_url,
           "\nafter ", attempts, " attempts.",
           if (is.character(status)) paste0("\nLast error: ", status),
           bypass, call. = FALSE)
    }
    Sys.sleep(5 * attempt)
  }

  got <- unname(tools::sha256sum(archive_tmp))
  if (!identical(tolower(got), tolower(expected))) {
    stop("SHA256 mismatch for vendor archive from\n  ", archive_url,
         "\nExpected: ", expected, "\nGot:      ", got,
         "\nThe release asset does not match the digest committed in ",
         "tools/vendor.sha256.", call. = FALSE)
  }

  copy(archive_tmp, vendor_xz)
  message("Vendor archive verified and placed at ", vendor_xz,
          " (", file.size(vendor_xz), " bytes)")
})
