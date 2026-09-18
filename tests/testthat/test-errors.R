test_that("a missing file is an io error", {
  err <- expect_error(to_markdown(file.path(tempdir(), "no-such-file.docx")),
                      class = "anydoc_error_io")
  expect_identical(err$code, "io")
})

test_that("unrecognisable bytes are an unsupported error", {
  path <- withr::local_tempfile(fileext = ".bin")
  writeBin(as.raw(c(0x00, 0x01, 0x02, 0x03)), path)
  err <- expect_error(to_markdown(path), class = "anydoc_error_unsupported")
  expect_identical(err$code, "unsupported")
})

test_that("every anydoc error is catchable by the general class too", {
  expect_error(to_markdown(file.path(tempdir(), "nope.docx")),
               class = "anydoc_error")
})

test_that("an image-only PDF reports which pages need OCR", {
  # anydoc does no OCR, and refuses the document rather than returning output
  # with the scanned pages silently missing.
  err <- expect_error(to_markdown(fixture("scan.pdf")),
                      class = "anydoc_error_needsOcr")
  expect_identical(err$code, "needsOcr")
  expect_type(err$pages, "integer")
  expect_identical(err$pages, 1:2)
  expect_identical(err$page_count, 2L)
})

test_that("pages is absent on errors that are not about OCR", {
  err <- expect_error(to_markdown(file.path(tempdir(), "nope.docx")),
                      class = "anydoc_error")
  expect_null(err$pages)
})

test_that("a directory given as a path is an io error, not a crash", {
  # file.exists() is true for a directory, so the R-level guard lets it
  # through and the failure has to come back from the read in Rust.
  err <- expect_error(to_markdown(withr::local_tempdir()),
                      class = "anydoc_error_io")
  expect_identical(err$code, "io")
})

test_that("path must be a single, non-NA string", {
  expect_error(to_markdown(NA_character_), "single, non-NA string")
  expect_error(to_markdown(c("a", "b")), "single, non-NA string")
  expect_error(to_markdown(1L), "single, non-NA string")
})

test_that("a structurally broken container is a malformed error", {
  # Half a docx: the zip central directory sits at the end, so truncating it
  # leaves a file that cannot be opened as a container at all. Derived from the
  # fixture rather than committed as a second binary, so it cannot drift away
  # from the document every other test uses.
  bytes <- fixture_bytes("report.docx")
  err <- expect_error(
    to_markdown_raw(utils::head(bytes, length(bytes) %/% 2L), format = "docx"),
    class = "anydoc_error_malformed"
  )
  expect_identical(err$code, "malformed")
  expect_null(err$pages)
})

test_that("a container missing the part it needs is a missingPart error", {
  # A perfectly valid zip that is simply not a Word document: an EPUB has no
  # word/document.xml. Naming the format forces the docx parser onto it.
  err <- expect_error(to_markdown_raw(fixture_bytes("report.epub"),
                                      format = "docx"),
                      class = "anydoc_error_missingPart")
  expect_identical(err$code, "missingPart")
})

test_that("conditions carry exactly the documented class hierarchy", {
  # The subclass is built from ConvertError::code(), so this pins the shape that
  # tryCatch() handlers in user code depend on.
  err <- tryCatch(to_markdown(fixture("scan.pdf")), error = function(e) e)
  expect_identical(
    class(err),
    c("anydoc_error_needsOcr", "anydoc_error", "error", "condition")
  )
})

# anydoc_error_encrypted and anydoc_error_resourceLimit have no test here.
# Producing them needs a password-protected OLE compound file and a document
# large enough to trip an internal limit; neither can be synthesised from the
# committed fixtures, and committing them would add binaries far larger than the
# rest of the suite. They are built by the same code path as every class above -
# anydoc_condition() derives the class from ConvertError::code() - which the
# malformed, missingPart, needsOcr, io and unsupported tests all exercise.
#
# anydoc_error_panic is covered on the Rust side, in src/rust/src/lib.rs, where
# a panic can be provoked deliberately.
