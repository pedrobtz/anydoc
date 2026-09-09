## R CMD check results

0 errors | 0 warnings | 1 note

Checked with `R CMD check --as-cran` on the vendored, offline build path -- the
one CRAN will use.

### NOTE: New submission

This is a first submission.

## If your build reports '_abort', possibly from 'abort' (C)

We do not see this warning, but we want to be up front about why, because the
reason is incidental rather than substantive.

`src/Makevars` deletes the cargo target directory once `anydoc.so` is linked.
That is done for disk usage -- it is ~300 MB, and `R CMD check` otherwise
carries it under `00_pkg_src` for the whole run -- but it has a side effect:
`symbols.rds` is written after `make all` finishes, so `libanydoc_r.a` is no
longer there to be scanned, and the check has nothing to attribute the symbol
to. The installed shared object does still reference `_abort`. Should the
ordering differ on any flavour and the warning appear, here is the explanation.

This symbol comes from the Rust standard library's panic runtime, not from any
call this package makes. `nm` over the 374 members of the static archive shows
exactly one referencing it: the crate's own codegen unit, which `lto = true` and
`codegen-units = 1` merge everything into.

It is reachable only through `std::panic::catch_unwind`, which this package uses
at every C entry point precisely so that a panic inside the Rust library cannot
unwind into R -- that would be undefined behaviour. Removing the symbol means
removing `catch_unwind`, trading a check warning for a real crash risk, so we
have not done that.

The package does not call `abort()`, `exit()`, `printf()` or any other
terminating or console-bypassing entry point of its own. Panics are captured by
an installed panic hook and returned to R as a classed condition, so nothing is
written to stdout or stderr either.

Cargo's `strip` option is not a lever here: it was measured both ways and is a
no-op for a staticlib (the archive must retain object symbols for the linker),
and `anydoc.so` is linked by R's `SHLIB`, not by cargo.

## Rust crates are downloaded at configure time

The vendored crate tree is 11 MB compressed -- roughly twice CRAN's source
tarball guidance -- so it is published as a GitHub Release asset and fetched by
`tools/vendor.R` at configure time, then built with `cargo build --offline`.

The expected SHA-256 is committed inside the source package, at
`tools/vendor.sha256`, as "Using Rust in CRAN packages" requires; it is not
downloaded alongside the archive, which would verify nothing about the host
serving both. A mismatch is a hard error, and `cargo build` runs `--offline
--locked` so a successful build is itself proof that nothing else was fetched
and that the dependency set matches the committed `Cargo.lock`.

We are aware this is against the letter of "Downloading should be avoided if at
all possible". The measurement above rules out inlining the tree, and the same
GitHub-Release mechanism is in use by `ggsql` on CRAN. We are happy to discuss
alternatives if this is not acceptable.

`cargo build` is limited to `-j 2` as the policy requires, and the `rustc`
version is printed to the installation log before compilation begins.

## Core usage at run time

The package holds itself to two cores while running, not only while building.
One of the vendored crates parses PDFs in parallel on rayon's global thread
pool, which by default sizes itself to every logical CPU. The package caps that
pool at two threads before the first conversion, so examples, tests and user
code stay inside the policy. Measured on an 8-core machine over 400 PDF
conversions: three OS threads in the process (R plus two workers), against nine
when the cap is lifted. An explicit `RAYON_NUM_THREADS` is honoured rather than
overridden.

## Rust toolchain requirement

`SystemRequirements` declares `rustc (>= 1.88)`, which the upstream `anydoc`
crate needs (it is edition 2024). That is newer than the two-year-old toolchain
the guidance suggests testing against; it is 14 months old at the time of
writing, the same age `rustc (>= 1.86)` was when `ggsql` 0.3.3 was published.
The README tells users on older distributions (Ubuntu 24.04 LTS ships 1.75) to
install rustup.

## Authorship of the vendored crates

`inst/AUTHORS` lists all 140 vendored crates with their versions, declared
licenses and authors, generated mechanically from `cargo metadata`.
`DESCRIPTION` has a `Copyright` field pointing to it, and `LICENSE.note` records
the five crates whose terms are not plain MIT.

## Method references

There are no published references describing the methods in this package; it is
a binding to the `anydoc` Rust library.
