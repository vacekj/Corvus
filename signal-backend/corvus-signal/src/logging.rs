//! Diagnostic log in `DIR/corvus-signal.log`, rotated at 5 MB. Nothing goes to stderr: Corvus
//! shows every stderr line in its status bar. Phone numbers are masked as a last line of defence;
//! code must not log message content or numbers in the first place.

use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use tracing_subscriber::filter::Targets;
use tracing_subscriber::fmt::MakeWriter;
use tracing_subscriber::prelude::*;

const MAX_LOG_BYTES: u64 = 5 * 1024 * 1024;

struct Inner {
    path: PathBuf,
    file: Option<File>,
    written: u64,
}

#[derive(Clone)]
pub struct LogFile {
    inner: Arc<Mutex<Inner>>,
}

impl LogFile {
    pub fn open(path: &Path) -> Self {
        let mut inner = Inner {
            path: path.to_owned(),
            file: None,
            written: 0,
        };
        inner.reopen();
        Self {
            inner: Arc::new(Mutex::new(inner)),
        }
    }
}

impl Inner {
    fn reopen(&mut self) {
        if let Some(parent) = self.path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let size = std::fs::metadata(&self.path).map(|m| m.len()).unwrap_or(0);
        if size >= MAX_LOG_BYTES {
            self.rotate();
            return;
        }
        self.file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
            .ok();
        self.written = size;
    }

    fn rotate(&mut self) {
        self.file = None;
        let old = self.path.with_extension("log.1");
        let _ = std::fs::rename(&self.path, old);
        self.file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
            .ok();
        self.written = 0;
    }

    fn write_line(&mut self, buf: &[u8]) {
        if self.written >= MAX_LOG_BYTES {
            self.rotate();
        }
        let masked = mask_numbers(&String::from_utf8_lossy(buf));
        if let Some(file) = &mut self.file {
            if file.write_all(masked.as_bytes()).is_ok() {
                self.written += masked.len() as u64;
            }
        }
    }
}

pub struct LogWriter {
    inner: Arc<Mutex<Inner>>,
    buf: Vec<u8>,
}

impl Write for LogWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.buf.extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Drop for LogWriter {
    fn drop(&mut self) {
        if self.buf.is_empty() {
            return;
        }
        if let Ok(mut inner) = self.inner.lock() {
            inner.write_line(&self.buf);
        }
    }
}

impl<'a> MakeWriter<'a> for LogFile {
    type Writer = LogWriter;

    fn make_writer(&'a self) -> Self::Writer {
        LogWriter {
            inner: self.inner.clone(),
            buf: Vec::new(),
        }
    }
}

/// Installs the file logger and a panic hook that logs instead of printing to stderr.
pub fn init(path: &Path) {
    let file = LogFile::open(path);
    let filter = std::env::var("CORVUS_SIGNAL_LOG")
        .ok()
        .and_then(|s| s.parse::<Targets>().ok())
        .unwrap_or_else(|| {
            Targets::new()
                .with_default(tracing::Level::WARN)
                .with_target("corvus_signal", tracing::Level::INFO)
        });
    let layer = tracing_subscriber::fmt::layer()
        .with_writer(file)
        .with_ansi(false)
        .with_target(true);
    let _ = tracing_subscriber::registry()
        .with(layer.with_filter(filter))
        .try_init();

    std::panic::set_hook(Box::new(|info| {
        let location = info
            .location()
            .map(|l| format!("{}:{}", l.file(), l.line()))
            .unwrap_or_default();
        tracing::error!(%location, "panic");
    }));
}

/// Replaces `+` followed by six or more digits with `+…NN` (last two digits kept).
pub fn mask_numbers(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    let mut last = 0;
    while i < bytes.len() {
        if bytes[i] == b'+' {
            let start = i + 1;
            let mut j = start;
            while j < bytes.len() && bytes[j].is_ascii_digit() {
                j += 1;
            }
            if j - start >= 6 {
                out.push_str(&s[last..i]);
                out.push_str("+…");
                out.push_str(&s[j - 2..j]);
                last = j;
                i = j;
                continue;
            }
        }
        i += 1;
    }
    out.push_str(&s[last..]);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn masks_numbers() {
        assert_eq!(mask_numbers("to +420123456789 ok"), "to +…89 ok");
        assert_eq!(mask_numbers("+12345"), "+12345");
        assert_eq!(mask_numbers("a+1234567"), "a+…67");
        assert_eq!(mask_numbers("ünï +4201234567"), "ünï +…67");
    }

    #[test]
    fn rotates() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("x.log");
        std::fs::write(&path, vec![b'a'; MAX_LOG_BYTES as usize]).unwrap();
        let log = LogFile::open(&path);
        {
            let mut w = log.make_writer();
            w.write_all(b"hello\n").unwrap();
        }
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "hello\n");
        assert!(tmp.path().join("x.log.1").exists());
    }
}
