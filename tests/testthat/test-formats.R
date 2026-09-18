test_that("anydoc_formats() lists the parsers the library actually has", {
  formats <- anydoc_formats()
  expect_type(formats, "character")
  expect_length(formats, 12L)
  expect_false(anyDuplicated(formats) > 0L)
  # Names a parser, not an extension: .xls/.xlsb/.xlsx are all "excel".
  expect_true(all(c("docx", "excel", "csv", "pdf") %in% formats))
})

test_that("an unknown format is rejected in R, before reaching the library", {
  expect_error(to_markdown(fixture("report.docx"), format = "wordperfect"),
               "Must be one of")
  expect_error(to_markdown_raw(raw(1), format = "wordperfect"),
               "Must be one of")
})

test_that("format must be NULL or a single string", {
  expect_error(to_markdown(fixture("report.docx"), format = c("docx", "odt")))
  expect_error(to_markdown(fixture("report.docx"), format = NA_character_))
  expect_error(to_markdown(fixture("report.docx"), format = 1L))
})

test_that("naming the wrong format fails rather than producing nonsense", {
  expect_error(to_markdown(fixture("report.docx"), format = "rtf"),
               class = "anydoc_error")
})
