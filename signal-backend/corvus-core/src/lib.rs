//! The Rust side of the macOS app in one static library:
//!
//! * the Signal backend, run inside the app (`cs_run_*`, see corvus-signal/include/corvus_signal.h),
//! * the history store's C interface (`sc_*`, history-store/include/history_store.h): reading a
//!   history file of an earlier version and wrapping the history database's key,
//! * SQLCipher (`sqlite3_*`), which the backend's store is built on and the app's history database uses.
//!
//! The crates' `#[no_mangle]` functions are the interface; nothing is added here.

pub use corvus_signal::ffi::*;
pub use history_store::*;
