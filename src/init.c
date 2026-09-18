#define R_NO_REMAP
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>
#include <stdint.h>

/* Mirrors `AnydocError` in src/rust/src/lib.rs. The layout is #[repr(C)] on the
   Rust side; if a field is added there it must be added here in the same
   position. */
typedef struct {
  char *code;
  char *message;
  char *pages;
  uint32_t page_count;
} anydoc_error_t;

/* Exported from the Rust staticlib. Declared by hand so that building this file
   needs no generated headers. */
char *anydoc_r_to_markdown(const char *path, const char *format,
                           anydoc_error_t *err);
char *anydoc_r_to_markdown_raw(const uint8_t *bytes, size_t len,
                               const char *format, anydoc_error_t *err);
char *anydoc_r_formats(void);
void anydoc_r_string_free(char *s);
void anydoc_r_error_free(anydoc_error_t *err);

/* What the Rust library handed us and we are obliged to hand back. Passed to
   R_UnwindProtect as the cleanup data, so it is released whether the result is
   built successfully or an R allocation failure unwinds part-way through. */
typedef struct {
  char *markdown;
  anydoc_error_t *err;
} rust_owned_t;

/* Runs on both the normal and the unwinding path.

   Nothing here allocates from R, which matters twice over: R_UnwindProtect
   calls this with its result value unprotected, and on the unwinding path the
   R error is still in flight. Plain free() calls are safe in both. */
static void free_rust_owned(void *data, Rboolean jump) {
  rust_owned_t *owned = (rust_owned_t *)data;
  (void)jump;
  anydoc_r_string_free(owned->markdown);
  anydoc_r_error_free(owned->err);
}

static SEXP scalar_utf8(const char *s) {
  SEXP c = PROTECT(Rf_mkCharCE(s, CE_UTF8));
  SEXP out = Rf_ScalarString(c);
  UNPROTECT(1);
  return out;
}

/* Builds list(markdown, code, message, pages, page_count).

   The error is deliberately not raised here. Rf_error() longjmps, which would
   flatten the variant code into message text that R could no longer branch on.
   Returning the pieces lets the R wrapper signal a classed condition instead.

   Every call below can raise on allocation failure, so this runs inside
   R_UnwindProtect rather than freeing the Rust strings itself. */
static SEXP build_result(void *data) {
  rust_owned_t *owned = (rust_owned_t *)data;
  char *markdown = owned->markdown;
  anydoc_error_t *err = owned->err;

  SEXP out = PROTECT(Rf_allocVector(VECSXP, 5));

  if (markdown != NULL) {
    SET_VECTOR_ELT(out, 0, scalar_utf8(markdown));
  } else {
    /* The Rust side fills in both fields whenever it returns NULL, so this is
       an invariant violation rather than a conversion outcome. Raising here is
       safe and does not leak: R_UnwindProtect runs free_rust_owned on the way
       out. It deliberately does not become an `anydoc_error` condition -
       inventing a cause ("io") for a failure the library never reported would
       send callers branching on it down the wrong path. */
    if (err->code == NULL || err->message == NULL) {
      Rf_error("anydoc: the library reported a failure with no %s. "
               "This is a bug in the package; please report it at "
               "https://github.com/pedrobtz/anydoc/issues",
               err->code == NULL ? "error code" : "error message");
    }
    SET_VECTOR_ELT(out, 1, scalar_utf8(err->code));
    SET_VECTOR_ELT(out, 2, scalar_utf8(err->message));
    if (err->pages != NULL) {
      SET_VECTOR_ELT(out, 3, scalar_utf8(err->pages));
      SET_VECTOR_ELT(out, 4, Rf_ScalarInteger((int)err->page_count));
    }
  }

  SEXP names = PROTECT(Rf_allocVector(STRSXP, 5));
  SET_STRING_ELT(names, 0, Rf_mkChar("markdown"));
  SET_STRING_ELT(names, 1, Rf_mkChar("code"));
  SET_STRING_ELT(names, 2, Rf_mkChar("message"));
  SET_STRING_ELT(names, 3, Rf_mkChar("pages"));
  SET_STRING_ELT(names, 4, Rf_mkChar("page_count"));
  Rf_setAttrib(out, R_NamesSymbol, names);

  UNPROTECT(2);
  return out;
}

static SEXP result_list(char *markdown, anydoc_error_t *err, SEXP cont) {
  rust_owned_t owned = {markdown, err};
  return R_UnwindProtect(build_result, &owned, free_rust_owned, &owned, cont);
}

/* NULL when `format` is NULL, meaning "detect from content". The R layer has
   already validated the name against anydoc_c_formats(). */
static const char *optional_format(SEXP format) {
  if (format == R_NilValue) {
    return NULL;
  }
  if (TYPEOF(format) != STRSXP || Rf_xlength(format) != 1 ||
      STRING_ELT(format, 0) == NA_STRING) {
    Rf_error("`format` must be NULL or a single, non-NA string.");
  }
  return Rf_translateCharUTF8(STRING_ELT(format, 0));
}

SEXP anydoc_c_to_markdown(SEXP path_sexp, SEXP format_sexp) {
  if (TYPEOF(path_sexp) != STRSXP || Rf_xlength(path_sexp) != 1 ||
      STRING_ELT(path_sexp, 0) == NA_STRING) {
    Rf_error("`path` must be a single, non-NA string.");
  }
  /* Both translations may allocate, so they run before any C-side state
     exists that a longjmp could strand. */
  const char *path = Rf_translateCharUTF8(STRING_ELT(path_sexp, 0));
  const char *format = optional_format(format_sexp);

  /* Made before the library call: R_MakeUnwindCont() allocates, and allocation
     failure is the very thing the continuation exists to survive. */
  SEXP cont = PROTECT(R_MakeUnwindCont());
  anydoc_error_t err = {NULL, NULL, NULL, 0};
  char *markdown = anydoc_r_to_markdown(path, format, &err);
  SEXP out = PROTECT(result_list(markdown, &err, cont));
  UNPROTECT(2);
  return out;
}

SEXP anydoc_c_to_markdown_raw(SEXP bytes_sexp, SEXP format_sexp) {
  if (TYPEOF(bytes_sexp) != RAWSXP) {
    Rf_error("`bytes` must be a raw vector.");
  }
  const char *format = optional_format(format_sexp);

  SEXP cont = PROTECT(R_MakeUnwindCont());
  anydoc_error_t err = {NULL, NULL, NULL, 0};
  char *markdown = anydoc_r_to_markdown_raw(
      RAW(bytes_sexp), (size_t)Rf_xlength(bytes_sexp), format, &err);
  SEXP out = PROTECT(result_list(markdown, &err, cont));
  UNPROTECT(2);
  return out;
}

static SEXP build_formats(void *data) {
  return scalar_utf8(*(char **)data);
}

static void free_formats(void *data, Rboolean jump) {
  (void)jump;
  anydoc_r_string_free(*(char **)data);
}

SEXP anydoc_c_formats(void) {
  SEXP cont = PROTECT(R_MakeUnwindCont());
  char *formats = anydoc_r_formats();
  SEXP out =
      PROTECT(R_UnwindProtect(build_formats, &formats, free_formats, &formats,
                              cont));
  UNPROTECT(2);
  return out;
}

static const R_CallMethodDef CallEntries[] = {
    {"anydoc_c_to_markdown", (DL_FUNC)&anydoc_c_to_markdown, 2},
    {"anydoc_c_to_markdown_raw", (DL_FUNC)&anydoc_c_to_markdown_raw, 2},
    {"anydoc_c_formats", (DL_FUNC)&anydoc_c_formats, 0},
    {NULL, NULL, 0}};

void R_init_anydoc(DllInfo *dll) {
  R_registerRoutines(dll, NULL, CallEntries, NULL, NULL);
  R_useDynamicSymbols(dll, FALSE);
  /* The R code calls through registered symbol objects, never by name. */
  R_forceSymbols(dll, TRUE);
}
