#' Convert a document to Markdown
#'
#' `to_markdown()` converts a file; `to_markdown_raw()` converts a document
#' already in memory. Both produce GitHub-Flavored Markdown.
#'
#' The format is normally detected from the document's *contents* rather than
#' its name, so a mislabelled file still converts correctly. For
#' `to_markdown()`, the file extension is consulted as a fallback; for
#' `to_markdown_raw()` there is no name to fall back on, so a format that
#' carries no signature must be named explicitly. In practice that means
#' **`format = "csv"` is required for CSV given as raw bytes**.
#'
#' @param path Path to a single document.
#' @param bytes A raw vector holding a single document.
#' @param format Format to parse as, or `NULL` (the default) to detect it. One
#'   of [anydoc_formats()]. Several file types share a parser, so this names the
#'   parser rather than the extension: `.xlsx`, `.xlsb` and `.xls` are all
#'   `"excel"`.
#'
#' @return A length-1 character vector of Markdown, marked as UTF-8.
#'
#' @section Resource use:
#' Conversion uses at most two cores. PDF parsing is internally parallel, and
#' its thread pool would otherwise grow to the number of logical CPUs; the
#' package caps it on first use. Set the `RAYON_NUM_THREADS` environment
#' variable before the first conversion to choose a different size.
#'
#' @section Errors:
#' Failures are signalled as conditions of class `anydoc_error`, with a more
#' specific subclass naming the cause, so callers branch on the cause rather
#' than on message text:
#'
#' \describe{
#'   \item{`anydoc_error_unsupported`}{The format is unknown or cannot be converted.}
#'   \item{`anydoc_error_needsOcr`}{A PDF with scanned or image-only pages.
#'     `anydoc` does not perform OCR, and returns nothing rather than silently
#'     omitting those pages. The condition carries `pages` (an integer vector of
#'     the 1-indexed pages needing OCR) and `page_count`.}
#'   \item{`anydoc_error_malformed`}{The document is structurally unusable.}
#'   \item{`anydoc_error_encrypted`}{The document is password-protected.}
#'   \item{`anydoc_error_resourceLimit`}{A fixed safety limit was exceeded.}
#'   \item{`anydoc_error_missingPart`}{A part required for any output is absent.}
#'   \item{`anydoc_error_io`}{The input could not be read.}
#'   \item{`anydoc_error_panic`}{The Rust library panicked. The condition
#'     message carries the panic message; the panic is caught at the C boundary
#'     rather than being allowed to unwind into R. Report these upstream.}
#' }
#'
#' @examples
#' csv <- tempfile(fileext = ".csv")
#' write.csv(head(mtcars[1:3], 3), csv)
#' cat(to_markdown(csv))
#'
#' # Raw bytes have no extension to fall back on, so CSV must be named.
#' cat(to_markdown_raw(charToRaw("a,b\n1,2\n"), format = "csv"))
#'
#' @export
to_markdown <- function(path, format = NULL) {
  if (!is.character(path) || length(path) != 1L || is.na(path)) {
    stop("`path` must be a single, non-NA string.", call. = FALSE)
  }
  format <- check_format(format)
  path <- path.expand(path)
  if (!file.exists(path)) {
    stop(anydoc_condition(list(code = "io", message =
      sprintf("File does not exist: %s", path))))
  }
  unwrap(.Call(anydoc_c_to_markdown, path, format))
}

#' @rdname to_markdown
#' @export
to_markdown_raw <- function(bytes, format = NULL) {
  if (!is.raw(bytes)) {
    stop("`bytes` must be a raw vector.", call. = FALSE)
  }
  unwrap(.Call(anydoc_c_to_markdown_raw, bytes, check_format(format)))
}

#' Formats that `anydoc` can parse
#'
#' The names accepted by the `format` argument of [to_markdown()]. Each names a
#' *parser*, so file types that share one are listed once: `"excel"` covers
#' `.xlsx`, `.xlsm`, `.xlsb` and `.xls`.
#'
#' @return A character vector of format names.
#' @examples
#' anydoc_formats()
#' @export
anydoc_formats <- function() {
  strsplit(.Call(anydoc_c_formats), ",", fixed = TRUE)[[1L]]
}

#' Validate the `format` argument against the Rust library's own list
#'
#' The list comes from the compiled library rather than a copy kept here, so the
#' two cannot drift apart.
#'
#' @noRd
check_format <- function(format) {
  if (is.null(format)) {
    return(NULL)
  }
  if (!is.character(format) || length(format) != 1L || is.na(format)) {
    stop("`format` must be NULL or a single, non-NA string.", call. = FALSE)
  }
  known <- anydoc_formats()
  if (!format %in% known) {
    stop(sprintf("Unknown `format`: \"%s\".\nMust be one of: %s.",
                 format, paste(known, collapse = ", ")), call. = FALSE)
  }
  format
}

#' Turn the C result list into Markdown, or signal a classed condition
#'
#' @noRd
unwrap <- function(result) {
  if (is.null(result$markdown)) {
    stop(anydoc_condition(result))
  }
  result$markdown
}

#' Build a classed condition from an upstream error code
#'
#' `code` is `ConvertError::code()` from the Rust crate, which upstream
#' documents as a stable identifier for the variant, so it is safe to put in the
#' class and branch on.
#'
#' @noRd
anydoc_condition <- function(result) {
  cond <- list(
    message = result$message,
    call = NULL,
    code = result$code
  )
  # `needsOcr` is the one variant with data worth acting on: the pages that
  # would need OCR. It arrives comma-separated because that keeps the C struct
  # to a single deallocator.
  if (!is.null(result$pages)) {
    cond$pages <- as.integer(strsplit(result$pages, ",", fixed = TRUE)[[1L]])
    cond$page_count <- result$page_count
  }
  structure(
    cond,
    class = c(paste0("anydoc_error_", result$code), "anydoc_error",
              "error", "condition")
  )
}
