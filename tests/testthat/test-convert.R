# The fixture table lives in helper-anydoc.R, shared with test-coverage.R.
for (case in fixture_cases()) {
  local({
    case <- case
    test_that(paste(case$file, "converts to Markdown"), {
      md <- to_markdown(fixture(case$file))
      expect_type(md, "character")
      expect_length(md, 1L)
      for (want in case$expect) {
        expect_true(grepl(want, md, fixed = TRUE),
                    info = sprintf("%s missing %s in:\n%s", case$file, want, md))
      }
    })
  })
}

test_that("format detection reads content, not the file name", {
  liar <- withr::local_tempfile(fileext = ".xlsx")
  file.copy(fixture("report.docx"), liar, overwrite = TRUE)
  expect_true(grepl("Quarterly Report", to_markdown(liar), fixed = TRUE))
})

test_that("an explicit format agrees with detection", {
  expect_identical(
    to_markdown(fixture("report.docx")),
    to_markdown(fixture("report.docx"), format = "docx")
  )
})

test_that("naming the parser a fixture actually needs converts it", {
  # The path entry point takes a different route through the Rust layer when a
  # format is named: it reads the file itself and calls to_markdown_bytes,
  # rather than letting upstream detect and dispatch.
  for (case in fixture_cases()) {
    md <- to_markdown(fixture(case$file), format = case$format)
    expect_true(nzchar(md), info = paste(case$file, "as", case$format))
  }
})

test_that("non-ASCII text round-trips as UTF-8", {
  # Escapes rather than literal accented characters: a non-ASCII byte in an R
  # source file is read in whatever encoding the parser assumes, which makes the
  # test depend on the locale it runs in (and R CMD check flags it besides).
  city <- "Z\u00fcrich"
  note <- "caf\u00e9"
  path <- withr::local_tempfile(fileext = ".csv")
  # writeBin, so the file holds UTF-8 whatever the session's native encoding is.
  writeBin(charToRaw(enc2utf8(sprintf("city,note\n%s,%s\n", city, note))), path)

  md <- to_markdown(path)
  expect_equal(Encoding(md), "UTF-8")
  expect_true(grepl(city, md, fixed = TRUE))
  expect_true(grepl(note, md, fixed = TRUE))
})

test_that("a non-ASCII file name converts", {
  # A different code path from the one above: this exercises the *path*
  # crossing the boundary (Rf_translateCharUTF8, then CStr::to_str in Rust),
  # where the earlier test only exercises the file's contents.
  dir <- withr::local_tempdir()
  path <- file.path(dir, "caf\u00e9-r\u00e9sum\u00e9.csv")
  written <- tryCatch({
    writeBin(charToRaw("Region,Units\nNorth,120\n"), path)
    file.exists(path)
  }, error = function(e) FALSE, warning = function(w) FALSE)
  # Not every filesystem and locale combination can hold the name; that is the
  # platform's limitation, not a conversion failure.
  skip_if_not(written, "filesystem cannot store a non-ASCII file name")

  md <- to_markdown(path)
  expect_true(grepl("| North | 120 |", md, fixed = TRUE))
})
