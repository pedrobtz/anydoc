# Every fixture holds the same source document, so what differs between these
# expectations is what each format is able to carry, not what it says.
cases <- list(
  list(file = "report.docx", expect = c("# Quarterly Report", "**12 percent**", "| North | 120 |")),
  list(file = "report.odt",  expect = c("# Quarterly Report", "**12 percent**", "| North | 120 |")),
  list(file = "report.epub", expect = c("# Quarterly Report", "**12 percent**", "| North | 120 |")),
  # A slide deck has no document title, so the heading arrives one level down.
  list(file = "report.pptx", expect = c("## Quarterly Report", "**12 percent**", "| North | 120 |")),
  list(file = "report.rtf",  expect = c("Quarterly Report", "**12 percent**", "| North | 120 |")),
  # Spreadsheets carry the table and nothing else.
  list(file = "report.xlsx", expect = c("| North | 120 |", "| South | 340 |")),
  list(file = "report.ods",  expect = c("| North | 120 |", "| South | 340 |")),
  list(file = "report.csv",  expect = c("| North | 120 |", "| South | 340 |")),
  # A presentation keeps the text but not the run-level formatting.
  list(file = "report.odp",  expect = c("Quarterly Report", "12 percent")),
  # PDF is converted by a different path entirely (pdf-inspector, which emits
  # Markdown directly rather than going through the document model).
  list(file = "report.pdf",  expect = c("Quarterly Report", "12 percent"))
)

for (case in cases) {
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
