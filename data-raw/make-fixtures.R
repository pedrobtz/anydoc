# Regenerates tests/testthat/fixtures/.
#
# The fixtures are committed rather than built during the test run, so the test
# suite needs none of the tools below and does not depend on pandoc being
# installed wherever R CMD check happens to run.
#
# Requires: pandoc, the openxlsx package, python3 (for the OpenDocument
# containers and the over-nested docx, which nothing else here can write), and
# qpdf (for the encrypted PDFs).
#
# Every fixture carries the same source document, so tests can assert the same
# heading, bold run, list and table survive whichever parser handled it.
#
# NOT COVERED: the legacy OLE formats `doc`, `ppt` and `xls`. Writing those
# needs LibreOffice (`soffice --convert-to`), which is not assumed here. See
# `test-coverage.R`, which fails if that gap ever widens.

fixtures <- file.path("tests", "testthat", "fixtures")
dir.create(fixtures, recursive = TRUE, showWarnings = FALSE)

src <- file.path(tempdir(), "src.md")
writeLines(c(
  "# Quarterly Report", "",
  "Revenue grew **12 percent** this quarter.", "",
  "- Widgets", "- Gadgets", "",
  "| Region | Units |", "| ------ | ----- |",
  "| North  | 120   |", "| South  | 340   |"
), src)

# --- pandoc-written formats ------------------------------------------------
# `--standalone` matters: without it pandoc emits an RTF *fragment* beginning
# `{\pard`, with no `{\rtf1` header. anydoc identifies formats by signature and
# correctly rejects that as "not an RTF file".
for (fmt in c("docx", "odt", "epub", "pptx", "rtf")) {
  out <- file.path(fixtures, paste0("report.", fmt))
  status <- system2("pandoc", c("--standalone", shQuote(src), "-o", shQuote(out)))
  if (status != 0) stop("pandoc failed for ", fmt)
}

# --- spreadsheet -----------------------------------------------------------
openxlsx::write.xlsx(
  data.frame(Region = c("North", "South"), Units = c(120L, 340L)),
  file.path(fixtures, "report.xlsx")
)

# --- csv -------------------------------------------------------------------
writeLines(c("Region,Units", "North,120", "South,340"),
           file.path(fixtures, "report.csv"))

# --- pdf: one with text, one image-only ------------------------------------
# The image-only file is the `needsOcr` fixture: anydoc does no OCR and refuses
# the whole document rather than returning pages with the scans silently
# dropped.
pdf_text <- file.path(fixtures, "report.pdf")
grDevices::pdf(pdf_text, width = 5, height = 3)
graphics::par(mar = c(0, 0, 0, 0)); graphics::plot.new()
graphics::text(0.5, 0.7, "Quarterly Report", cex = 2)
graphics::text(0.5, 0.4, "Revenue grew 12 percent this quarter.", cex = 1)
grDevices::dev.off()

pdf_scan <- file.path(fixtures, "scan.pdf")
set.seed(1)
grDevices::pdf(pdf_scan, width = 2, height = 2)
for (i in 1:2) {
  graphics::par(mar = c(0, 0, 0, 0)); graphics::plot.new()
  graphics::rasterImage(grDevices::as.raster(matrix(stats::runif(400), 20)),
                        0, 0, 1, 1)
}
grDevices::dev.off()

# --- OpenDocument spreadsheet / presentation -------------------------------
# Hand-built: pandoc writes odt but not ods or odp. `mimetype` must be the first
# entry and stored uncompressed, which is what makes the package identifiable
# from its bytes alone.
py <- file.path(tempdir(), "odf.py")
writeLines(sprintf('
import zipfile, sys
out = sys.argv[1]
NS = ("xmlns:office=\\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\\" "
      "xmlns:table=\\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\\" "
      "xmlns:text=\\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\\" "
      "xmlns:draw=\\"urn:oasis:names:tc:opendocument:xmlns:drawing:1.0\\" "
      "office:version=\\"1.2\\"")
def cell(v):
    return "<table:table-cell office:value-type=\\"string\\"><text:p>%%s</text:p></table:table-cell>" %% v
def row(cells):
    return "<table:table-row>" + "".join(cell(c) for c in cells) + "</table:table-row>"
SHEET = ("<office:spreadsheet><table:table table:name=\\"Sheet1\\">"
         + row(["Region", "Units"]) + row(["North", "120"]) + row(["South", "340"])
         + "</table:table></office:spreadsheet>")
SLIDE = ("<office:presentation><draw:page draw:name=\\"page1\\">"
         "<draw:frame><draw:text-box>"
         "<text:p>Quarterly Report</text:p>"
         "<text:p>Revenue grew 12 percent this quarter.</text:p>"
         "</draw:text-box></draw:frame></draw:page></office:presentation>")
kind = sys.argv[2]
mime = ("application/vnd.oasis.opendocument.spreadsheet" if kind == "ods"
        else "application/vnd.oasis.opendocument.presentation")
body = SHEET if kind == "ods" else SLIDE
content = ("<?xml version=\\"1.0\\" encoding=\\"UTF-8\\"?><office:document-content "
           + NS + "><office:body>" + body + "</office:body></office:document-content>")
manifest = ("<?xml version=\\"1.0\\" encoding=\\"UTF-8\\"?>"
  "<manifest:manifest xmlns:manifest=\\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\\" "
  "manifest:version=\\"1.2\\">"
  "<manifest:file-entry manifest:full-path=\\"/\\" manifest:media-type=\\"" + mime + "\\"/>"
  "<manifest:file-entry manifest:full-path=\\"content.xml\\" manifest:media-type=\\"text/xml\\"/>"
  "</manifest:manifest>")
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    zi = zipfile.ZipInfo("mimetype"); zi.compress_type = zipfile.ZIP_STORED
    z.writestr(zi, mime)
    z.writestr("META-INF/manifest.xml", manifest)
    z.writestr("content.xml", content)
'), py)
for (kind in c("ods", "odp")) {
  status <- system2("python3", c(shQuote(py),
                                 shQuote(file.path(fixtures, paste0("report.", kind))),
                                 kind))
  if (status != 0) stop("python3 failed for ", kind)
}

# --- error fixtures: encrypted and over-nested ------------------------------
# Derived from the fixtures above, so they stay tiny (a few KB each) and carry
# the same document.
#
# enc.pdf needs a password to open, so it raises `anydoc_error_encrypted`.
# owner.pdf is encrypted with an *empty* user password - the common
# "owner-locked" PDF that viewers open without asking - and must convert.
for (spec in list(c("enc.pdf", "secret"), c("owner.pdf", ""))) {
  status <- system2("qpdf", c(
    "--encrypt", paste0("--user-password=", spec[[2L]]),
    "--owner-password=owner", "--bits=256", "--",
    shQuote(pdf_text), shQuote(file.path(fixtures, spec[[1L]]))
  ))
  if (status != 0) stop("qpdf failed for ", spec[[1L]])
}

# nested.docx is report.docx with its body replaced by tables nested 1,000 deep
# (3,000 XML elements), past anydoc's fixed max_xml_depth of 256, so it raises
# `anydoc_error_resourceLimit`. Nesting compresses to almost nothing.
py_nested <- file.path(tempdir(), "nested.py")
writeLines('
import re, sys, zipfile
src, out, depth = sys.argv[1], sys.argv[2], int(sys.argv[3])
body = "<w:tbl><w:tr><w:tc>" * depth + "<w:p/>" + "</w:tc></w:tr></w:tbl>" * depth
with zipfile.ZipFile(src) as zin, zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zout:
    for item in zin.infolist():
        data = zin.read(item.filename)
        if item.filename == "word/document.xml":
            text = data.decode("utf-8")
            text = re.sub(r"<w:body>.*</w:body>", "<w:body>" + body + "</w:body>",
                          text, flags=re.S)
            data = text.encode("utf-8")
        zout.writestr(item, data)
', py_nested)
status <- system2("python3", c(shQuote(py_nested),
                               shQuote(file.path(fixtures, "report.docx")),
                               shQuote(file.path(fixtures, "nested.docx")),
                               "1000"))
if (status != 0) stop("python3 failed for nested.docx")

cat("Fixtures written to ", fixtures, ":\n", sep = "")
info <- file.info(list.files(fixtures, full.names = TRUE))
print(data.frame(bytes = info$size, row.names = basename(rownames(info))))
