# anydoc

<!-- badges: start -->
[![R-CMD-check](https://github.com/pedrobtz/anydoc/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/pedrobtz/anydoc/actions/workflows/R-CMD-check.yaml)
<!-- badges: end -->

Convert Word, PowerPoint, Excel, OpenDocument, RTF, EPUB, CSV and PDF files to
GitHub-Flavored Markdown, from R. Wraps the
[anydoc](https://github.com/firecrawl/anydoc) Rust library.

The format is detected from the file's **contents**, not its name, so a
mislabelled file still converts correctly. Every format is rendered through one
Markdown serializer, so headings, tables and lists come out consistently
whichever parser handled the input.

## Installation

``` r
install.packages("anydoc")
```

Or the development version:

``` r
# install.packages("pak")
pak::pak("pedrobtz/anydoc")
```

Either way the package compiles a Rust static library, so a Rust toolchain
([rustup](https://rust-lang.org/tools/install/)) has to be present. `anydoc`
requires **rustc >= 1.88**, which is newer than some distributions ship --
notably Ubuntu 24.04 LTS, which carries 1.75. R 4.5 or later is required.

## Usage

``` r
library(anydoc)

to_markdown("quarterly-report.docx")
#> [1] "# Quarterly Report\n\nRevenue grew **12 percent** this quarter.\n..."

cat(to_markdown("figures.xlsx"))
#> | Region | Units |
#> | --- | --- |
#> | North | 120 |
#> | South | 340 |
```

Documents already in memory convert too:

``` r
bytes <- readBin("report.docx", "raw", file.size("report.docx"))
to_markdown_raw(bytes)
```

Detection normally needs no help, but CSV carries no signature to detect. A
`.csv` *file* still works, because the extension is used as a fallback; CSV
given as raw bytes has to name the format:

``` r
to_markdown_raw(charToRaw("Region,Units\nNorth,120\n"), format = "csv")
```

`anydoc_formats()` lists the parsers available. Each names a parser rather than
an extension, so `.xlsx`, `.xlsm`, `.xlsb` and `.xls` are all `"excel"`:

``` r
anydoc_formats()
#>  [1] "doc"  "docx" "odt"  "pdf"  "ppt"  "pptx" "rtf"  "epub" "excel" "ods"
#> [11] "odp"  "csv"
```

## Errors

Failures are classed conditions, so you can branch on the cause rather than
matching message text:

``` r
tryCatch(
  to_markdown("scan.pdf"),
  anydoc_error_needsOcr = function(e) {
    sprintf("Pages %s of %d are scanned images.",
            paste(e$pages, collapse = ", "), e$page_count)
  }
)
#> [1] "Pages 1, 2 of 2 are scanned images."
```

`anydoc` does not perform OCR, and refuses a document with image-only pages
rather than returning output that silently omits them. Other subclasses are
`anydoc_error_unsupported`, `_malformed`, `_encrypted`, `_resourceLimit`,
`_missingPart`, `_io` and `_panic`; all inherit from `anydoc_error`.

## License

MIT. The package links Rust crates under their own permissive licenses; see
`LICENSE.note` and `inst/AUTHORS`.
