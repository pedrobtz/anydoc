# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An R package wrapping the Rust crate [`anydoc`](https://github.com/firecrawl/anydoc), to give the R
ecosystem a document → Markdown converter (docx, doc, pptx, ppt, xlsx/xls, odt/ods/odp, rtf, epub,
csv, pdf → GitHub-Flavored Markdown).

**Status (2026-09-04): 0.1.0, feature-complete and CRAN-clean.** Stages 1-6 are done and committed.
`R CMD check --as-cran` on the vendored offline path reports **0 errors, 0 warnings, 2 NOTEs** (`New
submission`, plus a local HTML Tidy complaint that is about the machine, not the package). 102 testthat
assertions and 7 cargo tests pass. Stage 7 (release) is the only one left.

**Requires R >= 4.5**, not 4.2: `tools/vendor.R` calls `tools::sha256sum()`, which was added in R 4.5.0
(`doc/NEWS`, the 4.5.0 section). On 4.2-4.4 a source install dies at configure time. Do not lower the
`Depends` floor without replacing that call.

The packaging and build machinery is a direct copy of the sibling package **`../data.fusion`** (itself
modelled on Posit's `ggsql`). That is the reference implementation — read its files rather than
reinventing the pipeline. See "Porting from data.fusion" below for what transfers and what does not.

## Upstream crate: `anydoc` (verified against 0.2.4)

MIT, `firecrawl/anydoc`, **edition 2024, `rust-version = 1.88`**, no cargo features (nothing to trim).
The entire public surface is three functions:

```rust
pub fn to_markdown(path: impl AsRef<Path>) -> Result<String, ConvertError>;
pub fn to_markdown_bytes(bytes: &[u8], format: impl Into<Option<Format>>) -> Result<String, ConvertError>;
pub fn to_document(bytes: &[u8], format: impl Into<Option<Format>>) -> Result<model::Document, ConvertError>;
```

Consequences that shape the whole design:

- **The FFI surface is tiny** — bytes/path in, one UTF-8 `String` out. This is not a streaming or
  stateful API; there is no connection, cursor, or handle to manage.
- `Format` has 12 variants and is normally **detected from content** (`Format::from_bytes`), with the
  file extension as fallback. **CSV carries no signature** and must be named explicitly — the one case
  where the R API has to let the caller force a format.
- **PDF is special**: it converts to Markdown directly via `pdf-inspector` and has *no* document-model
  form, so `to_document()` errors for PDFs. Scanned/image-only pages yield `ConvertError::NeedsOcr`
  (anydoc does no OCR) — surface that as a distinct, actionable R condition, not a generic error.

## Intended architecture

```
anydoc (R package)
├── R/            thin wrappers: file/raw → character, condition mapping
└── src/
    ├── init.c    R_init_anydoc, .Call registration, SEXP <-> C string
    └── rust/     staticlib wrapping the anydoc crate behind extern "C"
```

**No `extendr`.** The boundary is three calls returning a string; a hand-written `extern "C"` layer plus
`init.c` is enough, and it avoids adding `rextendr` (not installed locally) to the toolchain. Follow
`../data.fusion/src/init.c` for the registration idiom (`R_registerRoutines`, `R_useDynamicSymbols(dll,
FALSE)`, symbols declared by hand so no generated headers are needed).

`AnydocError` is declared `#[repr(C)]` in `src/rust/src/lib.rs` **and again** as `anydoc_error_t` in
`src/init.c`. Nothing checks that the two agree - a field added on one side and not the other is silent
memory corruption, not a compile error. Change them together.

The one ownership rule the C ABI must get right: Rust allocates the returned Markdown `String`, so the
crate must export a matching free function and `init.c` must call it after copying into a `mkCharLenCE(...,
CE_UTF8)`. Never `free()` a Rust allocation from C. Output is UTF-8 — mark it as such rather than letting
it fall into the native encoding.

Two further invariants, both load-bearing and both easy to undo by accident:

- **The frees run inside `R_UnwindProtect`.** Building the result list makes ~10 allocating R calls, any of
  which can raise; a longjmp past `anydoc_r_string_free` would strand a Rust `String` the size of the whole
  converted document. `R_MakeUnwindCont()` is therefore created *before* the library call - allocating it
  afterwards would fail in exactly the situation it exists to survive. The cleanup handler must never
  allocate from R: `R_UnwindProtect` calls it with the result value unprotected.
- **Panics are captured, not printed.** `run()` swaps in a panic hook that stores the message instead of
  letting the default one write it to stderr, then restores the previous hook. Compiled code writing to
  stderr bypasses R's console (invisible in GUI front-ends) and is named in the `checking compiled code`
  warning text. The swap is process-global, so it is serialised behind a mutex. The message reaches R as
  the `anydoc_error_panic` condition.

**Wrapper crate name — convention, not a constraint.** The R package is `anydoc` *and* the upstream Rust
dependency is `anydoc`. This was checked: a local crate named `anydoc` depending on registry `anydoc`
resolves and compiles fine (edition 2018+ resolves a bare `anydoc::` path to the extern crate; the local
crate is `crate::`). Name the wrapper crate `anydoc-r`/`libanydoc_r.a` anyway, matching
`data.fusion`'s `datafusion-r` — otherwise build logs read `Checking anydoc v0.2.4` immediately followed by
`Checking anydoc v0.0.0`, and `-lanydoc` sits confusingly next to the `anydoc.so` it links into.

## The vendoring pipeline (built at stage 4)

CRAN forbids a source tarball this large, so the vendored crate tree ships **out-of-band** as a GitHub
Release asset and is fetched at configure time. Six files cooperate; reading any one alone is misleading:

1. **`configure` / `configure.win`** - two lines, run `tools/vendor.R` then `tools/config.R`.
2. **`tools/vendor.R`** - acquires `src/rust/vendor.tar.xz`. Decision tree, in order:
   `ANYDOC_VENDOR_TARBALL` (local archive, not digest-checked - the developer chose the file) ->
   `src/rust/vendor/` already extracted -> archive already present -> `NOT_CRAN` set (skip; cargo goes
   online) -> download from `github.com/pedrobtz/anydoc/releases/download/v<DESCRIPTION Version>/` and
   verify against **`tools/vendor.sha256`, committed in the package**. `ANYDOC_VENDOR_URL` overrides the
   base URL for a mirror and is still verified.
3. **`tools/vendor.sha256`** - the expected digest. CRAN requires the checksum to be embedded in the
   source package, and a digest downloaded beside the archive would verify nothing about the host serving
   both. A placeholder here is a hard error on the download path, not a skipped check.
4. **`tools/config.R`** - finds `cargo`, logs the `cargo`/`rustc` versions (CRAN asks for this in the
   install log), then generates `src/Makevars` from `src/Makevars.in`, substituting `@PROFILE_DIR@`,
   `@ADDITIONAL_LIBS@` and `@CRAN_FLAGS@` (`--offline` unless `NOT_CRAN`).
5. **`src/Makevars.in`** - unpacks the archive, copies `rust/vendor-config.toml` into a build-local
   `CARGO_HOME` so `[source.crates-io] replace-with = "vendored-sources"` applies, builds `--offline -j 2`,
   then `rust_clean` deletes the vendor dir. It fails loudly when a config was written but `vendor/` is
   missing - a truncated archive otherwise surfaces as an inscrutable cargo registry error.
6. **`tools/make-vendor.sh`** - builds the archive and prints the digest to commit.

**Release order is inverted relative to `data.fusion`, and this matters.** Because the digest must be
inside the source package, the archive has to exist *before* the version referencing it is tagged:

```
tools/make-vendor.sh                    # build archive, print digest
echo <digest> > tools/vendor.sha256     # commit it
create release vX.Y.Z, upload src/rust/vendor.tar.xz
tag / submit
```

So the stage-5 release workflow must **verify that the uploaded asset matches the committed digest**, not
rebuild the archive and upload whatever it produced. Rebuilding is not safe: `tar` and `xz` are not
byte-reproducible across machines and versions, so a rebuilt archive would fail the very check the
committed digest exists to perform.

**A release without this asset breaks every source install**, and CRAN's periodic rebuilds need GitHub
reachable at configure time.

## What `R CMD build` sweeps up (verified 2026-08-28)

`R CMD build` takes the *whole working directory* except what `.Rbuildignore` excludes, and this tree has
a 978 MB `src/rust/target/` sitting in it. The current tarball is **86 KB / 51 entries** and correct, but
the protection is worth understanding before editing `.Rbuildignore`.

R excludes some things on its own - verified by planting each one and rebuilding: `*.tar.gz` (so a
previous build in the root is safe), `*.Rcheck/`, `.DS_Store`, `.Rhistory`, `.git`, and `src/*.o` /
`src/*.so`. Do not add patterns for these.

What R does **not** protect is `src/rust/`, which is a live cargo working directory: a planted
`src/rust/scratch.log` shipped. Blacklisting junk extensions is a losing game, so the two rules there are
**whitelists**, using the fact that `.Rbuildignore` patterns are Perl regexes and so support negative
lookahead:

```
^src/rust/(?!Cargo\.toml$|Cargo\.lock$|vendor-config\.toml$|src(/|$)).
^src/rust/src/(?!([^.]+|.*\.rs)$).
```

The first admits only the three manifest files and `src/`; the second admits only `.rs` files and
extensionless paths, the latter so nested module directories keep working - both confirmed by planting
`lib.rs.orig`, `.rej`, `.swp`, `Cargo.toml.bak`, `flamegraph.svg` and `.idea/` (all dropped) alongside a
real `src/formats/mod.rs` (kept).

If a Rust build ever needs another top-level file (a `build.rs`, a `.cargo/config.toml`), it must be added
to the first pattern's allow-list or it will silently not ship.

## Measured packaging numbers (this repo, `anydoc` 0.2.4, 2026-08-28)

`cargo vendor` on a staticlib crate depending only on `anydoc = "0.2"`:

| | |
|---|---|
| Crates | 140 |
| Raw `vendor/` | 96 MB |
| `vendor.tar.gz` | 18 MB |
| `vendor.tar.xz` | **11 MB** |

11 MB xz is ~2x CRAN's 5 MB source-tarball guideline, so the tree cannot ship inside the tarball — the
out-of-band fetch is justified by measurement, not copied on faith. It is also **half** of
`data.fusion`'s 21 MB and under a third of `ggsql`'s 36.76 MB, both of which CRAN accepts under this same
mechanism, so size is not a blocker here.

There is no feature-flag lever: `anydoc` declares no cargo features. The tree is dominated by
`windows-sys` (18 MB — `cargo vendor` pulls every target platform regardless of build target), then
`csv`, `pdf-inspector`, `libc`, `encoding_rs` at 6-7 MB each.

## CRAN policy for Rust packages (checked against the official page, 2026-08-28)

The governing document is [Using Rust in CRAN packages](https://cran.r-project.org/web/packages/using_rust.html).
Four of its requirements bear directly on the plan above; two of them the `data.fusion` code does **not**
currently satisfy, so do not port those parts unchanged.

**1. The rustc floor is newer than CRAN asks for — acceptable in practice, but declare it.**
CRAN: *"test before submission with at least a two-year-old version of cargo, and preferably one four or
more years old."* `anydoc` requires rustc >= 1.88 (released 2025-06-26, **14 months** old today) and
edition 2024 (needs >= 1.85, 2025-02-20, 18 months). Both sit inside the two-year window, so the letter of
the guidance is not met. It is very likely survivable: **`ggsql` 0.3.3 is on CRAN (2026-06-03) declaring
`rustc (>= 1.86)`** — released 2025-04-03, the same ~14-month age at its own publication — with Windows
and macOS binaries built. Declare the floor explicitly:
`SystemRequirements: Cargo (Rust's package manager), rustc (>= 1.88)`.

CRAN's own machines are fine (Debian testing/forky ships rustc 1.95.0). The casualties are LTS distros:
**Ubuntu 24.04 LTS ships rustc 1.75.0**, below even edition 2024's 1.85 floor, so those users must install
`rustup`. Say so in the README; the r-rust FAQ flags this class of user explicitly.

**2. `cargo build` must be limited to 1-2 jobs — `data.fusion`'s `Makevars.in` does not do this.**
CRAN: *"`cargo build -j N` defaults to the number of 'logical CPUs'. This usually exceeds the maximum
allowed in the CRAN policy, so needs to be set explicitly to N=1 or 2."* Add `-j 2` to the `cargo build`
line when porting; it is missing there and is a straightforward policy violation.

**3. The checksum is embedded in the source package. DONE.** CRAN: *"check that the download is the
expected code by some sort of checksum. The expected checksum needs to be embedded in the source
package."* `data.fusion` fetches `vendor.tar.xz.sha256` from the *same GitHub release* as the archive it
validates, which meets neither the letter nor the point of that. Here the digest is committed as
`tools/vendor.sha256` and the sidecar download is gone - which is what forces the release ordering above.

**4. Every vendored crate's authorship must be credited.** CRAN: *"the authorship and copyright
information for the Rust code must be included in the `DESCRIPTION` file. That includes any Rust sources
included as dependencies."* That is 140 crates here. Generate it mechanically from `cargo metadata` — the
`r-rust/hellorust` template has a script — into `inst/AUTHORS`, referenced from `DESCRIPTION`.

**Standing risk: the whole out-of-band fetch is against the written policy.** CRAN: *"Downloading should
be avoided if at all possible"* and, pointedly, *"CRAN does not regard `github.com` ... as sufficiently
reliable."* The 11 MB measurement rules out inlining the tree, and `ggsql` demonstrates CRAN has accepted
exactly this GitHub-Release mechanism — but that is precedent, not permission, and it is the most likely
ground for a rejection. Cite `ggsql` if challenged, and expect to have to argue it.

## Porting from `../data.fusion`

Copy nearly verbatim, renaming `datafusion` → `anydoc` and `DATAFUSION_` → `ANYDOC_`:
`configure`, `configure.win`, `cleanup`, `cleanup.win`, `tools/vendor.R`, `tools/config.R`,
`src/Makevars.in`, `src/Makevars.win.in`, `src/rust/vendor-config.toml`, `.Rbuildignore`, `.gitignore`,
and the workflows. `Swatinem/rust-cache` carries over, but the **"Increase disk space" step does not**:
that exists for DataFusion's build, and this tree is an order of magnitude smaller (280 MB release
`target/`, 14 MB staticlib, 7.1 MB `anydoc.so`), which fits a stock runner comfortably.

Do **not** port the architecture. `data.fusion` is a query engine: ADBC, `adbi`, DBI, dbplyr, S4 driver
and connection classes, an `AdbcDriverInit` export from `init.c`. None of that applies — `anydoc` is a
pure function, so it needs no ADBC layer, no `adbcdrivermanager`/`adbi` dependencies, and no S4.
When porting `Makevars.in`, add `-j 2` to the `cargo build` line (see CRAN policy above).
`src/Makevars.win.in`'s Windows link list (`-lws2_32 -ladvapi32 -luserenv -lbcrypt -lntdll -lncrypt`) is
DataFusion's; trim it to what this crate actually needs.

## Commands

Local toolchain is present: cargo 1.97.1, R 4.6.1, with devtools/roxygen2/testthat/cpp11 installed.

```r
devtools::load_all()                  # load + recompile src/ (main dev loop)
devtools::document()                  # regenerate NAMESPACE and man/ from roxygen
devtools::test()                      # all tests
devtools::test(filter = "convert")    # tests/testthat/test-convert.R only
devtools::check()                     # full R CMD check
```

```sh
R CMD INSTALL --no-multiarch --with-keep.source .
Rscript -e 'testthat::test_file("tests/testthat/test-convert.R")'
```

Rust-only iteration is much faster inside the crate than through a package reload:

```sh
cd src/rust && cargo build && cargo test
cargo fmt --all --check && cargo clippy --all-targets -- -D warnings   # what CI enforces
```

**Set one of these before building, or a cold build fails.** Since stage 4 there is a `configure`, and
on a tree with no `src/rust/vendor/` it tries to download the release asset. No release exists yet, so a
fresh clone gets a 404 - correct behaviour, but a trap:

```sh
export NOT_CRAN=true                                    # simplest: cargo resolves online
export ANYDOC_VENDOR_TARBALL="$PWD/.vendor/vendor.tar.xz"   # or build fully offline
```

`.vendor/` is a gitignored local cache; rebuild the archive with `tools/make-vendor.sh` if it is missing.
`ANYDOC_VENDOR_URL` overrides the download base for a mirror. Note that an incremental
`devtools::test()` will *appear* to work without either variable, because `configure` only re-runs when
the shared object is out of date - the failure shows up on a clean tree.

`NAMESPACE` is roxygen-generated — never hand-edit it; edit the roxygen block in `R/` and re-run
`devtools::document()`. Note that declaring `@useDynLib anydoc` before `src/` compiles anything will make
the package fail to load.

## Roadmap

Dependency-ordered. Each stage has a verifiable done-condition; do not start a stage until the previous
one's check passes.

**Note the ordering choice:** the FFI vertical slice (stage 1) comes *before* the vendoring pipeline
(stage 4), which is the opposite of how `data.fusion`'s files present themselves. Build the packaging
machinery last, because until it exists a build failure has one plausible cause instead of two. Stages 1-3
run with `NOT_CRAN=true`, letting cargo resolve crates online.

- **Stage 1 - Foundation + vertical FFI slice. DONE (2026-08-28).** `DESCRIPTION`/`LICENSE` filled in; `src/rust/` wrapper
  crate (`anydoc-r` -> `libanydoc_r.a`); `extern "C"` entry point with panic containment and an explicit
  string-free; `src/init.c` registration; one R function.
  *Verified:* RTF and CSV convert from R, UTF-8 round-trips (`café naïve`), and failures arrive
  as `anydoc_error_io` / `anydoc_error_unsupported` conditions. `src/Makevars` is checked in and builds
  online; stage 4 replaces it with the generated pair.
- **Stage 2 - R API surface. DONE (2026-08-28).** Raw-vector input; explicit `format=` (mandatory for CSV, which carries no
  signature); UTF-8 marking; `ConvertError` -> typed R conditions, with `NeedsOcr` its own class.
  *Verified:* `to_markdown(path, format=)`, `to_markdown_raw(bytes, format=)` and `anydoc_formats()`
  (12 names, read from the compiled library so the R list cannot drift). Content beats a lying extension;
  CSV bytes without `format=` fail as documented; `needsOcr` carries `pages` as an integer vector.
- **Stage 3 - Tests + fixtures. DONE (2026-08-28).** testthat over a fixture per format, plus the error paths (unsupported
  bytes, PDF passed to the document-model path, OCR-needed PDF).
  *Verified:* 94 testthat assertions and 5 cargo tests, all green. 11 fixtures committed under
  `tests/testthat/fixtures/` (~72 KB total), regenerated by `data-raw/make-fixtures.R`.

  Fixture provenance: pandoc writes docx/odt/epub/pptx/rtf, `openxlsx` writes xlsx, `grDevices::pdf()`
  writes both PDF paths (text operators, and `rasterImage()` alone for the image-only `scan.pdf` that
  raises `needsOcr`), and ods/odp are hand-built ZIP containers because nothing available writes them.
  **Pandoc needs `--standalone`**: without it the RTF output is a fragment beginning `{\pard` with no
  `{\rtf1` header, which anydoc correctly rejects as "not an RTF file".

  **Known gap: `doc` and `ppt` have no fixture** - legacy OLE compound files need LibreOffice
  (`soffice --convert-to`) to write, which the generator does not assume. `xls` is not in the gap because
  it shares the `"excel"` parser that `report.xlsx` covers. `test-coverage.R` asserts the gap is *exactly*
  those two, so it fails if it ever widens.

  Note for later stages: keep non-ASCII out of R sources - use `\u` escapes and `writeBin(charToRaw(
  enc2utf8(...)))`. A literal accented character in a test file is read in whatever encoding the parser
  assumes, which made the UTF-8 test pass or fail by locale, and R CMD check flags it anyway.

- **Stage 4 - CRAN build pipeline. DONE (2026-08-28).** Port `configure`(`.win`), `tools/vendor.R`, `tools/config.R`,
  `Makevars.in`(`.win.in`), `cleanup`(`.win`), `vendor-config.toml` - with the two policy fixes from above:
  `-j 2`, and a checksum committed into the package rather than downloaded beside the archive.
  *Verified:* 88 KB source tarball (no vendor archive, no `target/`, no generated `Makevars`), and
  `R CMD INSTALL` of that tarball completes with `cargo build --offline`, which cannot reach the network
  at all - so a successful build is itself the proof. The installed package converts and errors correctly.
  Digest handling was exercised on all four paths: good digest verifies, corrupted archive is refused,
  placeholder digest fails with guidance, `NOT_CRAN` still bypasses.

  Archive (unchanged for 0.1.0): 10,981,572 bytes,
  `b654a4fa0c50d4949390072e9854f1aa7fe97d38159d85f88a68937c012601d1`, cached in `.vendor/` (gitignored)
  and committed as `tools/vendor.sha256`. The version bump changes only the *URL* `tools/vendor.R` builds
  (now `v0.1.0`); the archive and its digest are still valid, so **do not rebuild it** - `tar`/`xz` are not
  byte-reproducible and a rebuild would invalidate the committed digest for no reason.

  `cargo build` and `cargo vendor` both run `--locked`, so a stale `Cargo.lock` fails loudly instead of
  silently resolving a different `anydoc` 0.2.x than the one that was vendored and audited.

  `rust_clean` deletes the *whole* `target/` on the CRAN path (300 MB -> 18 MB in `.Rcheck`) and only
  `release/build` when `NOT_CRAN` is set, so the developer loop keeps its incremental rebuilds.
  `tools/config.R` picks between the two.

- **Stage 5 - CI. DONE, still never pushed (2026-09-04).** `R-CMD-check.yaml`, `rust-check.yaml` (fmt/clippy/test), and a release workflow that
  **verifies the uploaded asset against `tools/vendor.sha256`** rather than rebuilding it (see the
  release-order note above). Runners need the "Increase disk space" step and `Swatinem/rust-cache`.
  *Written:* `rust-check.yaml` (fmt/clippy/test), `R-CMD-check.yaml` (5-way matrix), `release.yaml`.

  *Verified locally, as far as is possible without pushing:* all three parse; the gates CI enforces run
  clean here (`cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test`);
  `release.yaml`'s shell logic dry-runs correctly (tag/Version extraction, digest extraction, digest
  comparison against the real archive, and the placeholder guard); and its embedded smoke test passes
  against the installed package.

  *Not verified:* whether the workflows go green on GitHub. That needs a push, which still has not
  happened.

  **`error-on` must stay at `"error"`.** `r-lib/actions/check-r-package@v2` defaults to
  `args: 'c("--no-manual", "--as-cran")'` and `error-on: '"warning"'`, and `tools:::.check_packages`'s
  `check_rust()` is **not** gated on `--as-cran` - it fires whenever the install log contains `cargo build`
  or `   Compiling `. With `NOT_CRAN: true` the log also contains `Downloading crates ...`, so the default
  would fail every matrix job. Strictness is not given up: a follow-up step greps `00check.log` for
  `^\* checking .* \.\.\. WARNING$` and fails on anything outside an explicit two-name allow-list
  (`compiled code`, `Rust compilation`).

  `R-CMD-check.yaml` sets `NOT_CRAN: true` because a development version has no published vendor archive
  and `configure` would 404 looking for one. The vendored offline path is covered by `release.yaml`, which
  installs through the real published asset with no overrides and then runs `--as-cran` against it - the
  only build that can pass `checking Rust compilation`.

- **Stage 6 - CRAN compliance. DONE (2026-09-04).**

  *Done:* `inst/AUTHORS` generated by `data-raw/make-authors.R` from `cargo metadata` (140 crates -
  exactly matching the vendored count); a `Copyright:` field in `DESCRIPTION` pointing to it; a
  `LICENSE.note`; and a real README.

  *Licensing finding.* All 140 crates are permissive, but three offer **no MIT option** - `ryu`
  (Apache-2.0 OR BSL-1.0), `zopfli` (Apache-2.0), `zlib-rs` (Zlib) - and two carry conjunctive terms:
  `encoding_rs` ((Apache-2.0 OR MIT) AND BSD-3-Clause) and `unicode-ident` ((MIT OR Apache-2.0) AND
  Unicode-3.0). `License: MIT + file LICENSE` alone does not disclose that, which is what `LICENSE.note`
  is for. Re-run `data-raw/make-authors.R` after any dependency change; it prints the license spread so a
  newly-introduced non-permissive license would be visible.

  ***Trap: never run `R CMD check --as-cran` with `NOT_CRAN=true`.*** Doing so produces a spurious
  second WARNING:

  ```
  * checking Rust compilation ... WARNING
    Downloads Rust crates
  ```

  `tools:::.check_packages$check_rust()` simply greps the *install log* for the literal string
  `"Downloading crates ..."`. `NOT_CRAN` makes cargo resolve online, so the string appears and the check
  fires. Check the way CRAN will actually build it instead - which also confirms the design is sound:

  ```sh
  ANYDOC_VENDOR_TARBALL="$PWD/.vendor/vendor.tar.xz" \
    R CMD check --as-cran anydoc_*.tar.gz     # -> checking Rust compilation ... OK
  ```

  That same check also greps the log for a `rustc <version>` line; `tools/config.R` prints one, so it
  passes.

  *Current state on the vendored path:* **0 errors, 0 warnings, 2 NOTEs** - `New submission`, and a
  local HTML Tidy complaint that is about this machine's `tidy`, not the package.

  **The `_abort` WARNING is gone, but for an incidental reason - know this before changing `rust_clean`.**
  `R CMD check` used to report:

  ```
  * checking compiled code ... WARNING
    Found '_abort', possibly from 'abort' (C)
      Object: 'rust/target/release/libanydoc_r.a'
  ```

  It stopped being reported when `rust_clean` began deleting the whole `target/`. The mechanism, verified
  by diffing `symbols.rds` between two runs: `tools:::.shlib_objects_symbol_tables()` runs **after**
  `make all`, and collects tables from the package's objects plus any `*.a` under `..` matching a `-l` in
  `PKG_LIBS`. Before, `symbols.rds` held tables for `init.o` *and*
  `rust/target/release/libanydoc_r.a`; now it holds only `init.o`, so the checker has nothing to attribute
  the symbol to. **The installed `anydoc.so` still has an undefined `_abort`** (`nm -u` confirms). CRAN
  runs the same install, so it should see the same OK - but this is evidence going missing, not a fix.

  Keep the explanation in `cran-comments.md` regardless, because a flavour that orders things differently
  will surface it again. The substance: `nm` shows exactly one archive member of 374 referencing it - our
  own codegen unit, since `lto = true` / `codegen-units = 1` merge everything into one. It comes from
  **Rust std's panic runtime, not from anything this package calls**, and cannot be removed without
  dropping `catch_unwind`, which is what stops a Rust panic unwinding into C. Do not do that. Cargo's
  `strip` is also *not* a lever - measured, it is a no-op for a staticlib, and `anydoc.so` is linked by R
  rather than cargo.
- **Stage 7 - Release. IN PROGRESS.** Everything below the first step is done already: the archive exists
  in `.vendor/`, and its digest is committed. Remaining, in this order - **the order matters**, because the
  digest has to be inside the source package before the version referencing it is tagged:

  ```sh
  git push -u origin develop            # first push; confirms the three workflows go green
  # open a PR to main, merge
  gh release create v0.1.0 --title "anydoc 0.1.0" --notes-file NEWS.md
  gh release upload v0.1.0 .vendor/vendor.tar.xz   # the exact cached file, NOT a rebuild
  # release.yaml then verifies the asset against tools/vendor.sha256 and runs --as-cran through it
  ```

  Only after `release.yaml` is green: submit `anydoc_0.1.0.tar.gz` with `cran-comments.md`.

  **Do not rebuild the archive.** `tar`/`xz` are not byte-reproducible, so a rebuild produces a different
  digest and fails the very check the committed digest exists to perform. `release.yaml` verifies, it does
  not rebuild, for the same reason.

- **Stage 8 - Wider `anydoc` surface (deferred to 0.2; recorded 2026-08-28, reconfirmed 2026-09-04).**
  The crate has **no cargo features**, so there is nothing to toggle - but there is unused *API*, needing
  no new dependencies:

  - **`Format::from_bytes` / `from_path`** - detection without conversion. An `anydoc_detect_format(path)`
    returning `"docx"` or `NA` is cheap and useful for triaging a directory of mixed files.
  - **`to_document()` -> `model::Document`** - the information-preserving model that `to_markdown()`
    flattens away. `assets` retains *every embedded binary asset (image, object payload)*, which Markdown
    output cannot express at all; `notes` carries footnote/endnote bodies with `NoteKind`; `body` carries
    typed blocks with `Table::grid`, styles and links. **Unsupported for PDF** - PDFs convert straight to
    Markdown and have no document-model form.

  Cost is very uneven. Detection is small. The full model means marshalling a nested Rust tree across the
  C ABI into R lists - real work, and worth its own stage. The high-value middle path is **assets only**
  (`anydoc_extract_assets(path)` -> raw vectors plus MIME types), most of the practical benefit for a
  fraction of the marshalling.

  **Adding *new formats* is blocked upstream, not by the crate tree (checked 2026-09-04).** `render` is a
  **private** module in `anydoc`; `document_to_markdown` is not exported. `pub mod model` is public and
  `Document { blocks, notes, assets }` has public fields, so a `Document` can be built - but not rendered.
  Any reader written in `anydoc-r` would have to ship its own Markdown emitter, which breaks the promise
  `DESCRIPTION` and the README both make, that every format goes through one serializer. Preferred order:
  (1) upstream the reader to `firecrawl/anydoc`; (2) failing that, ask upstream to make `render::markdown`
  public; (3) only as a last resort, emit Markdown ourselves.

  Crate-wise, declaring an already-vendored crate as a direct dependency of `anydoc-r` costs nothing - same
  140 crates, same archive, same digest, same `inst/AUTHORS` - provided the version requirement resolves to
  the locked version. So `quick-xml` (XML/SVG/XHTML/RSS), `csv` (TSV/PSV) and `encoding_rs` (legacy text
  encodings) are free. **JSON is not**: `serde_json` is absent, and so is the `serde` facade - the tree has
  only `serde_core` and `serde_derive`. HTML is also unavailable (no `html5ever`/`scraper`; `quick-xml`
  will not parse real-world HTML). A new dependency means a new lock, archive, digest and release asset.
