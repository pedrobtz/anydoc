# anydoc 0.1.0

First release.

* `to_markdown()` converts a document on disk to GitHub Flavored Markdown, and
  `to_markdown_raw()` converts one already held as a raw vector. Word,
  PowerPoint, Excel, OpenDocument, RTF, EPUB, CSV and PDF inputs are supported.

* The input format is detected from file contents rather than from the
  extension, with the extension as a fallback for `to_markdown()`. CSV carries
  no signature, so `format = "csv"` is required when passing CSV as raw bytes.

* `anydoc_formats()` lists the parsers the compiled library actually has, read
  from the library itself rather than from a copy kept in R.

* Conversion uses at most two cores. The PDF parser is internally parallel, so
  the package caps its thread pool rather than letting it grow to the machine's
  core count; set `RAYON_NUM_THREADS` to choose a different size.

* Failures are signalled as conditions classed `anydoc_error`, with a subclass
  naming the cause (`anydoc_error_unsupported`, `_needsOcr`, `_malformed`,
  `_encrypted`, `_resourceLimit`, `_missingPart`, `_io`, `_panic`). A PDF with
  scanned pages raises `anydoc_error_needsOcr` carrying `pages` and
  `page_count`, rather than returning output with those pages silently missing.
