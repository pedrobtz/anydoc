//! C ABI over the `anydoc` crate, for the R package to call via `.Call`.
//!
//! Three rules govern everything here:
//!
//! 1. No panic may cross the boundary - unwinding into C is undefined
//!    behaviour - so every entry point wraps its work in `catch_unwind`, and
//!    installs a hook that captures the message instead of letting the default
//!    one write it to stderr. Compiled code that writes to stderr bypasses R's
//!    console (invisible in GUI front-ends, and flagged by `R CMD check`).
//! 2. Every string handed to C is allocated by Rust and must be returned to
//!    `anydoc_r_string_free` (or, for an [`AnydocError`], to
//!    `anydoc_r_error_free`). C must never `free()` one.
//! 3. Errors travel in an [`AnydocError`] out-parameter rather than as a
//!    return value, so the R layer can raise a *classed* condition. The `code`
//!    field is `ConvertError::code()`, which upstream documents as the stable
//!    machine-readable variant name that bindings branch on.

use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::sync::{Mutex, MutexGuard, OnceLock};

use anydoc::{ConvertError, Format};

/// Out-parameter carrying a failed conversion back to C.
///
/// The caller zeroes one of these and passes a pointer to it; on failure the
/// library fills it in and the caller must pass it to
/// [`anydoc_r_error_free`]. Kept as a struct rather than a run of out-pointers
/// so that adding variant-specific detail does not change every signature.
#[repr(C)]
pub struct AnydocError {
    /// Stable variant name from `ConvertError::code()`, e.g. `"needsOcr"`.
    pub code: *mut c_char,
    /// Human-readable message.
    pub message: *mut c_char,
    /// `needsOcr` only: 1-indexed pages needing OCR, comma-separated
    /// (`"2,5,6,7"`). NULL for every other variant. A string rather than an
    /// array so the whole struct needs exactly one deallocator.
    pub pages: *mut c_char,
    /// `needsOcr` only: total pages in the document. Zero otherwise.
    pub page_count: u32,
}

/// Move a Rust string onto the C heap.
///
/// A NUL byte would truncate the value at the C boundary, so any are stripped
/// rather than failing the conversion: Markdown text is the payload, and a
/// document that smuggles in a NUL is not worth losing the whole conversion
/// over.
fn into_c_string(s: String) -> *mut c_char {
    match CString::new(s) {
        Ok(c) => c.into_raw(),
        Err(e) => {
            let mut bytes = e.into_vec();
            bytes.retain(|b| *b != 0);
            CString::new(bytes)
                .unwrap_or_else(|_| CString::default())
                .into_raw()
        }
    }
}

/// R-facing format names. Several upstream container variants share a parser,
/// so this is the parser list, not the extension list: `.xlsx`, `.xlsb` and
/// `.xls` are all `"excel"`.
fn parse_format(name: &str) -> Option<Format> {
    Some(match name {
        "doc" => Format::Doc,
        "docx" => Format::Docx,
        "odt" => Format::Odt,
        "pdf" => Format::Pdf,
        "ppt" => Format::Ppt,
        "pptx" => Format::Pptx,
        "rtf" => Format::Rtf,
        "epub" => Format::Epub,
        "excel" => Format::Excel,
        "ods" => Format::Ods,
        "odp" => Format::Odp,
        "csv" => Format::Csv,
        _ => return None,
    })
}

/// Read an optional format argument: NULL means "detect from content".
unsafe fn read_format(format: *const c_char) -> Result<Option<Format>, ConvertError> {
    if format.is_null() {
        return Ok(None);
    }
    let name = unsafe { CStr::from_ptr(format) }
        .to_str()
        .map_err(|_| ConvertError::Unsupported("format name is not valid UTF-8".to_owned()))?;
    parse_format(name)
        .map(Some)
        .ok_or_else(|| ConvertError::Unsupported(format!("unknown format: {name}")))
}

/// Fill the error out-parameter from a `ConvertError`.
unsafe fn set_error(out: *mut AnydocError, e: &ConvertError) {
    if out.is_null() {
        return;
    }
    let (pages, page_count) = match e {
        ConvertError::NeedsOcr { pages, page_count } => {
            let joined = pages
                .iter()
                .map(u32::to_string)
                .collect::<Vec<_>>()
                .join(",");
            (into_c_string(joined), *page_count)
        }
        _ => (ptr::null_mut(), 0),
    };
    unsafe {
        (*out).code = into_c_string(e.code().to_owned());
        (*out).message = into_c_string(e.to_string());
        (*out).pages = pages;
        (*out).page_count = page_count;
    }
}

/// Report a failure that is ours rather than the library's.
unsafe fn set_plain_error(out: *mut AnydocError, code: &str, message: &str) {
    if out.is_null() {
        return;
    }
    unsafe {
        (*out).code = into_c_string(code.to_owned());
        (*out).message = into_c_string(message.to_owned());
        (*out).pages = ptr::null_mut();
        (*out).page_count = 0;
    }
}

/// Lock a mutex, ignoring poisoning.
///
/// Poisoning only records that some thread panicked while holding the lock,
/// which is precisely the situation this module exists to handle. The guarded
/// values are a `()` token and a replaceable `Option<String>`, neither of which
/// a panic can leave in an inconsistent state.
fn lock_ignoring_poison<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Serialises the panic-hook swap in [`run`].
///
/// `set_hook` is process-global, so two conversions running at once would
/// otherwise race to install and restore each other's hooks. R is
/// single-threaded per session, but nothing stops this library being loaded
/// somewhere that is not.
fn panic_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

/// Where the hook installed by [`run`] leaves the panic message.
fn panic_message() -> &'static Mutex<Option<String>> {
    static MESSAGE: OnceLock<Mutex<Option<String>>> = OnceLock::new();
    MESSAGE.get_or_init(|| Mutex::new(None))
}

/// Run a conversion, funnelling every outcome into the C calling convention.
unsafe fn run(
    err: *mut AnydocError,
    f: impl FnOnce() -> Result<String, ConvertError>,
) -> *mut c_char {
    // Held across the whole swap-run-restore sequence, so a concurrent call
    // cannot restore the default hook while this one is still running.
    let _serialised = lock_ignoring_poison(panic_lock());
    *lock_ignoring_poison(panic_message()) = None;

    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(|info| {
        // Capture rather than print. `info` renders as the location plus the
        // payload, which is the whole of what the default hook would have
        // written to stderr.
        *lock_ignoring_poison(panic_message()) = Some(info.to_string());
    }));
    let outcome = catch_unwind(AssertUnwindSafe(f));
    std::panic::set_hook(previous);

    match outcome {
        Ok(Ok(markdown)) => into_c_string(markdown),
        Ok(Err(e)) => {
            unsafe { set_error(err, &e) };
            ptr::null_mut()
        }
        // The payload itself is not reliably a string, so the hook's rendering
        // of it is the only reliable account of what happened.
        Err(_) => {
            let message = match lock_ignoring_poison(panic_message()).take() {
                Some(m) => format!("the anydoc library panicked: {m}"),
                None => "the anydoc library panicked, without a message".to_owned(),
            };
            unsafe { set_plain_error(err, "panic", &message) };
            ptr::null_mut()
        }
    }
}

/// Convert the document at `path` to Markdown.
///
/// `format` names the parser, or is NULL to detect it from the content (with
/// the file extension as fallback, which is what makes an unnamed `.csv` work).
/// Returns an owned UTF-8 C string, or NULL with `err` filled in.
///
/// # Safety
/// `path` must be a valid NUL-terminated C string; `format` must be NULL or the
/// same; `err` must be NULL or point to a writable, zeroed [`AnydocError`].
#[no_mangle]
pub unsafe extern "C" fn anydoc_r_to_markdown(
    path: *const c_char,
    format: *const c_char,
    err: *mut AnydocError,
) -> *mut c_char {
    unsafe {
        run(err, || {
            if path.is_null() {
                return Err(ConvertError::Unsupported("path is NULL".to_owned()));
            }
            let path = CStr::from_ptr(path)
                .to_str()
                .map_err(|_| ConvertError::Unsupported("path is not valid UTF-8".to_owned()))?;
            match read_format(format)? {
                // Delegate to upstream so the extension fallback applies.
                None => anydoc::to_markdown(path),
                // An explicit format still has to read the file itself.
                Some(f) => anydoc::to_markdown_bytes(&std::fs::read(path)?, f),
            }
        })
    }
}

/// Convert an in-memory document to Markdown.
///
/// Unlike the path entry point there is no extension to fall back on, so
/// signature-less formats (CSV) must name `format` explicitly.
///
/// # Safety
/// `bytes` must point to at least `len` readable bytes (or be NULL when `len`
/// is 0); `format` and `err` as for [`anydoc_r_to_markdown`].
#[no_mangle]
pub unsafe extern "C" fn anydoc_r_to_markdown_raw(
    bytes: *const u8,
    len: usize,
    format: *const c_char,
    err: *mut AnydocError,
) -> *mut c_char {
    unsafe {
        run(err, || {
            let slice = if len == 0 {
                &[][..]
            } else if bytes.is_null() {
                return Err(ConvertError::Unsupported("bytes is NULL".to_owned()));
            } else {
                std::slice::from_raw_parts(bytes, len)
            };
            anydoc::to_markdown_bytes(slice, read_format(format)?)
        })
    }
}

/// The format names [`anydoc_r_to_markdown`] accepts, comma-separated.
///
/// Exported so the R layer validates against the Rust list rather than a
/// hand-copied one that could drift.
///
/// # Safety
/// The returned string must be released with [`anydoc_r_string_free`].
#[no_mangle]
pub extern "C" fn anydoc_r_formats() -> *mut c_char {
    into_c_string("doc,docx,odt,pdf,ppt,pptx,rtf,epub,excel,ods,odp,csv".to_owned())
}

/// Release a string returned by this library.
///
/// # Safety
/// `s` must be NULL, or a pointer this library returned that has not already
/// been freed.
#[no_mangle]
pub unsafe extern "C" fn anydoc_r_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}

/// Release the contents of an [`AnydocError`] and reset it to empty.
///
/// # Safety
/// `err` must be NULL or point to an `AnydocError` this library filled in.
#[no_mangle]
pub unsafe extern "C" fn anydoc_r_error_free(err: *mut AnydocError) {
    if err.is_null() {
        return;
    }
    unsafe {
        anydoc_r_string_free((*err).code);
        anydoc_r_string_free((*err).message);
        anydoc_r_string_free((*err).pages);
        (*err).code = ptr::null_mut();
        (*err).message = ptr::null_mut();
        (*err).pages = ptr::null_mut();
        (*err).page_count = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn empty_error() -> AnydocError {
        AnydocError {
            code: ptr::null_mut(),
            message: ptr::null_mut(),
            pages: ptr::null_mut(),
            page_count: 0,
        }
    }

    fn text(p: *const c_char) -> String {
        assert!(!p.is_null());
        unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_owned()
    }

    const RTF: &[u8] = br"{\rtf1\ansi Hello Markdown\par}";

    #[test]
    fn converts_a_file_with_and_without_an_explicit_format() {
        let dir = std::env::temp_dir().join("anydoc_r_test");
        std::fs::create_dir_all(&dir).unwrap();
        let rtf = dir.join("hello.rtf");
        std::fs::write(&rtf, RTF).unwrap();
        let path = CString::new(rtf.to_str().unwrap()).unwrap();
        let rtf_fmt = CString::new("rtf").unwrap();

        for format in [ptr::null(), rtf_fmt.as_ptr()] {
            let mut err = empty_error();
            let out = unsafe { anydoc_r_to_markdown(path.as_ptr(), format, &mut err) };
            assert!(err.code.is_null(), "out-param set on success");
            assert!(text(out).contains("Hello Markdown"));
            unsafe { anydoc_r_string_free(out) };
        }
    }

    #[test]
    fn converts_bytes_and_requires_a_format_for_csv() {
        let mut err = empty_error();
        let out =
            unsafe { anydoc_r_to_markdown_raw(RTF.as_ptr(), RTF.len(), ptr::null(), &mut err) };
        assert!(text(out).contains("Hello Markdown"));
        unsafe { anydoc_r_string_free(out) };

        // CSV carries no signature, so detection must fail...
        let csv = b"a,b\n1,2\n";
        let mut err = empty_error();
        let out =
            unsafe { anydoc_r_to_markdown_raw(csv.as_ptr(), csv.len(), ptr::null(), &mut err) };
        assert!(out.is_null());
        assert_eq!(text(err.code), "unsupported");
        unsafe { anydoc_r_error_free(&mut err) };

        // ...and naming it must succeed.
        let csv_fmt = CString::new("csv").unwrap();
        let mut err = empty_error();
        let out = unsafe {
            anydoc_r_to_markdown_raw(csv.as_ptr(), csv.len(), csv_fmt.as_ptr(), &mut err)
        };
        assert!(text(out).contains("| a | b |"));
        unsafe { anydoc_r_string_free(out) };
    }

    #[test]
    fn rejects_an_unknown_format_name() {
        let bogus = CString::new("wordperfect").unwrap();
        let mut err = empty_error();
        let out =
            unsafe { anydoc_r_to_markdown_raw(RTF.as_ptr(), RTF.len(), bogus.as_ptr(), &mut err) };
        assert!(out.is_null());
        assert_eq!(text(err.code), "unsupported");
        assert!(text(err.message).contains("wordperfect"));
        unsafe { anydoc_r_error_free(&mut err) };
    }

    /// Every name `anydoc_r_formats` advertises must actually parse - the R
    /// layer builds its validation list from it.
    #[test]
    fn every_advertised_format_parses() {
        let list = anydoc_r_formats();
        let names = text(list);
        unsafe { anydoc_r_string_free(list) };
        let names: Vec<&str> = names.split(',').collect();
        assert_eq!(names.len(), 12);
        for name in names {
            assert!(parse_format(name).is_some(), "unparsed format: {name}");
        }
    }

    /// The panic path must produce a classed error carrying the message, not a
    /// note pointing at stderr - compiled code writing to stderr bypasses R's
    /// console entirely.
    #[test]
    fn a_panic_becomes_an_error_that_carries_its_message() {
        let mut err = empty_error();
        let out = unsafe { run(&mut err, || panic!("boom, a synthetic panic")) };
        assert!(out.is_null());
        assert_eq!(text(err.code), "panic");
        assert!(
            text(err.message).contains("boom, a synthetic panic"),
            "panic message was not captured: {}",
            text(err.message)
        );
        unsafe { anydoc_r_error_free(&mut err) };
    }

    /// The hook is process-global and swapped in and out around every call, so
    /// a panic must leave the next conversion working normally.
    #[test]
    fn a_panic_does_not_disturb_the_next_conversion() {
        let mut err = empty_error();
        let out = unsafe { run(&mut err, || panic!("first")) };
        assert!(out.is_null());
        unsafe { anydoc_r_error_free(&mut err) };

        let mut err = empty_error();
        let out =
            unsafe { anydoc_r_to_markdown_raw(RTF.as_ptr(), RTF.len(), ptr::null(), &mut err) };
        assert!(text(out).contains("Hello Markdown"));
        unsafe { anydoc_r_string_free(out) };
    }

    #[test]
    fn error_free_is_idempotent() {
        let mut err = empty_error();
        unsafe { anydoc_r_error_free(&mut err) };
        unsafe { anydoc_r_error_free(&mut err) };
    }
}
