//! The `corvus-signal` command: the backend library on this process's standard streams.

use std::io::{BufRead as _, Write as _};
use std::process::ExitCode;
use std::rc::Rc;

fn main() -> ExitCode {
    let (tx, input) = tokio::sync::mpsc::unbounded_channel();
    // Standard input is read on a thread of its own; the end of it closes the channel.
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            match line {
                Ok(line) => {
                    if tx.send(line).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });
    let io = corvus_signal::Io {
        input,
        out: Rc::new(|line| {
            let mut out = std::io::stdout().lock();
            let _ = writeln!(out, "{line}");
            let _ = out.flush();
        }),
        err: Rc::new(|line| eprintln!("{line}")),
        signals: true,
    };
    ExitCode::from(corvus_signal::run(std::env::args().skip(1).collect(), io))
}
