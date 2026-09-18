test_that("raw vectors convert", {
  expect_identical(to_markdown_raw(fixture_bytes("report.docx")),
                   to_markdown(fixture("report.docx")))
})

test_that("raw input rejects anything that is not a raw vector", {
  expect_error(to_markdown_raw("report.docx"), "must be a raw vector")
  expect_error(to_markdown_raw(1:10), "must be a raw vector")
})

test_that("CSV bytes need an explicit format, having no signature to detect", {
  bytes <- charToRaw("Region,Units\nNorth,120\n")
  expect_error(to_markdown_raw(bytes), class = "anydoc_error_unsupported")
  expect_true(grepl("| North | 120 |", to_markdown_raw(bytes, format = "csv"),
                    fixed = TRUE))
})

test_that("an empty raw vector fails rather than returning empty Markdown", {
  expect_error(to_markdown_raw(raw(0)), class = "anydoc_error")
})

test_that("raw input marks its output as UTF-8", {
  # test-convert.R covers the path entry point; this is the other one, and the
  # two reach mkCharCE() through different C functions.
  #
  # \u escapes rather than literal accented characters: a non-ASCII byte in an
  # R source file is read in whatever encoding the parser assumes.
  city <- "Z\u00fcrich"
  md <- to_markdown_raw(charToRaw(enc2utf8(sprintf("city\n%s\n", city))),
                        format = "csv")
  expect_equal(Encoding(md), "UTF-8")
  expect_true(grepl(city, md, fixed = TRUE))
})
