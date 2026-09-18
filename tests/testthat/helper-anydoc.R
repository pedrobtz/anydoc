# Fixtures are committed, not generated here; see data-raw/make-fixtures.R.
fixture <- function(name) test_path("fixtures", name)

# Reading a fixture as raw is wanted in three files, and getting the `n =`
# wrong truncates silently rather than failing, so it lives in one place.
fixture_bytes <- function(name) {
  path <- fixture(name)
  readBin(path, "raw", n = file.size(path))
}

# The convertible fixtures, with the parser each one exercises.
#
# Shared rather than duplicated: test-convert.R converts every entry, and
# test-coverage.R derives from `format` which parsers have no fixture at all.
# Kept as one table so adding a fixture cannot update one of those and not the
# other.
#
# Every fixture holds the same source document, so what differs between the
# expectations is what each format is able to carry, not what it says.
# scan.pdf is deliberately absent: it is the fixture that must fail, and
# test-errors.R owns it.
fixture_cases <- function() {
  list(
    list(file = "report.docx", format = "docx",
         expect = c("# Quarterly Report", "**12 percent**", "| North | 120 |")),
    list(file = "report.odt", format = "odt",
         expect = c("# Quarterly Report", "**12 percent**", "| North | 120 |")),
    list(file = "report.epub", format = "epub",
         expect = c("# Quarterly Report", "**12 percent**", "| North | 120 |")),
    # A slide deck has no document title, so the heading arrives one level down.
    list(file = "report.pptx", format = "pptx",
         expect = c("## Quarterly Report", "**12 percent**", "| North | 120 |")),
    list(file = "report.rtf", format = "rtf",
         expect = c("Quarterly Report", "**12 percent**", "| North | 120 |")),
    # Spreadsheets carry the table and nothing else.
    list(file = "report.xlsx", format = "excel",
         expect = c("| North | 120 |", "| South | 340 |")),
    list(file = "report.ods", format = "ods",
         expect = c("| North | 120 |", "| South | 340 |")),
    list(file = "report.csv", format = "csv",
         expect = c("| North | 120 |", "| South | 340 |")),
    # A presentation keeps the text but not the run-level formatting.
    list(file = "report.odp", format = "odp",
         expect = c("Quarterly Report", "12 percent")),
    # PDF is converted by a different path entirely (pdf-inspector, which emits
    # Markdown directly rather than going through the document model).
    list(file = "report.pdf", format = "pdf",
         expect = c("Quarterly Report", "12 percent"))
  )
}
