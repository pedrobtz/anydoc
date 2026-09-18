# Guards the fixture gap rather than leaving it implicit. If someone adds a
# fixture for a legacy format, this fails and tells them to shorten the list;
# if a new format appears upstream with no fixture, it fails too.
test_that("only the legacy OLE formats lack a fixture", {
  # Derived from the fixture table rather than restated, so adding a fixture
  # cannot leave this list claiming a gap that no longer exists.
  covered <- unique(vapply(fixture_cases(), function(x) x$format, character(1)))
  # doc, ppt and xls are OLE compound files; writing one needs LibreOffice,
  # which data-raw/make-fixtures.R does not assume. "xls" is not listed
  # separately because it shares the "excel" parser, which report.xlsx covers.
  expect_setequal(setdiff(anydoc_formats(), covered), c("doc", "ppt"))
})

test_that("every committed fixture is a usable input", {
  # Catches a fixture that was committed but is corrupt, truncated, or was
  # regenerated into a form the library no longer accepts - which a per-format
  # test would only reveal for the formats it happens to name.
  files <- list.files(test_path("fixtures"), full.names = TRUE)
  expect_gt(length(files), 0L)

  for (path in files) {
    if (basename(path) == "scan.pdf") {
      # The one fixture that is meant to fail; see test-errors.R.
      expect_error(to_markdown(path), class = "anydoc_error_needsOcr")
    } else {
      md <- to_markdown(path)
      expect_true(nzchar(md), info = paste(basename(path), "converted to nothing"))
    }
  }
})
