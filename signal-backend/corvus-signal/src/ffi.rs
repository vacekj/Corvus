//! C interface for an app that links the backend instead of starting it as a process.
//!
//! A run is one command line on a thread of its own. Its standard output and error arrive line by
//! line through a callback (on that thread), its standard input is fed with `cs_run_send`, and the
//! end of input (`cs_run_close_input`) ends a `jsonRpc` run or cancels a `link`, as closing the
//! pipe of the process does. The declarations are in `include/corvus_signal.h`.

use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::rc::Rc;
use std::sync::Mutex;

use tokio::sync::mpsc;

/// `stream` is 1 for standard output and 2 for standard error; `line` has no line end and is only
/// valid during the call.
pub type LineFn = unsafe extern "C" fn(ctx: *mut c_void, stream: c_int, line: *const c_char);
/// The run has ended with this exit code (101: it panicked). Nothing is called after it.
pub type ExitFn = unsafe extern "C" fn(ctx: *mut c_void, code: c_int);

pub struct CsRun {
    input: Mutex<Option<mpsc::UnboundedSender<String>>>,
}

#[derive(Clone, Copy)]
struct Callbacks {
    on_line: LineFn,
    on_exit: ExitFn,
    ctx: usize,
}

// The context pointer is the caller's and is only handed back to its callbacks.
unsafe impl Send for Callbacks {}

impl Callbacks {
    fn line(&self, stream: c_int, line: &str) {
        // A line cannot hold a NUL in the protocol; drop any rather than cut the line short.
        let text = if line.contains('\0') { line.replace('\0', "") } else { line.to_owned() };
        if let Ok(c) = CString::new(text) {
            unsafe { (self.on_line)(self.ctx as *mut c_void, stream, c.as_ptr()) }
        }
    }
}

/// Starts a run of the command line `argv[0..argc]` (the arguments after the program name).
/// Returns a handle to free with `cs_run_free` once `on_exit` was called, or NULL if the thread
/// could not be started or an argument is not UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cs_run_start(
    argc: c_int,
    argv: *const *const c_char,
    on_line: LineFn,
    on_exit: ExitFn,
    ctx: *mut c_void,
) -> *mut CsRun {
    let mut args = Vec::new();
    for i in 0..argc.max(0) as usize {
        let p = unsafe { *argv.add(i) };
        if p.is_null() {
            return std::ptr::null_mut();
        }
        match unsafe { CStr::from_ptr(p) }.to_str() {
            Ok(s) => args.push(s.to_owned()),
            Err(_) => return std::ptr::null_mut(),
        }
    }
    let (tx, input) = mpsc::unbounded_channel();
    let callbacks = Callbacks { on_line, on_exit, ctx: ctx as usize };
    let spawned = std::thread::Builder::new()
        .name("corvus-signal".into())
        // The process ran the backend on its main thread: keep that much stack.
        .stack_size(8 * 1024 * 1024)
        .spawn(move || {
            let code = catch_unwind(AssertUnwindSafe(|| {
                let io = crate::Io {
                    input,
                    out: Rc::new(move |line| callbacks.line(1, line)),
                    err: Rc::new(move |line| callbacks.line(2, line)),
                    signals: false,
                };
                crate::run(args, io)
            }))
            .unwrap_or(101);
            unsafe { (callbacks.on_exit)(callbacks.ctx as *mut c_void, c_int::from(code)) }
        });
    match spawned {
        Ok(_) => Box::into_raw(Box::new(CsRun { input: Mutex::new(Some(tx)) })),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Feeds one line of standard input to the run (the store key first, then JSON-RPC requests).
/// Returns 0, or -1 if the run has ended or its input was closed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cs_run_send(run: *mut CsRun, line: *const c_char) -> c_int {
    let (Some(run), false) = (unsafe { run.as_ref() }, line.is_null()) else { return -1 };
    let Ok(text) = unsafe { CStr::from_ptr(line) }.to_str() else { return -1 };
    let guard = run.input.lock().unwrap_or_else(|e| e.into_inner());
    match guard.as_ref() {
        Some(tx) if tx.send(text.to_owned()).is_ok() => 0,
        _ => -1,
    }
}

/// The end of standard input: a `jsonRpc` run shuts down, a `link` run is cancelled.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cs_run_close_input(run: *mut CsRun) {
    if let Some(run) = unsafe { run.as_ref() } {
        run.input.lock().unwrap_or_else(|e| e.into_inner()).take();
    }
}

/// Frees the handle. The run itself goes on until it ends (close its input first).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cs_run_free(run: *mut CsRun) {
    if !run.is_null() {
        drop(unsafe { Box::from_raw(run) });
    }
}
