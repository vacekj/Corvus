//! corvus-signal: Corvus's Signal backend (replaces signal-cli). See DESIGN.md.
//!
//! The backend is a library: `run` is the command line (`--version`, `listAccounts`, `link`, `jsonRpc`,
//! `deleteLocalAccountData`) with its standard input and output handed in as `Io`. The `corvus-signal`
//! binary runs it on the process's stdin/stdout; the macOS app links the library and runs it on a
//! thread of its own (`ffi`), with the same lines going through callbacks instead of pipes.

mod avatars;
mod ctx;
mod envelope;
mod files;
mod logging;
mod media;
mod methods;
mod receive;
mod rpc;
mod store;
mod tls_proxy;

pub mod ffi;

use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;

use futures::channel::oneshot;
use presage::Manager;
use presage::libsignal_service::configuration::SignalServers;
use presage::store::StateStore;
use tokio::sync::mpsc;

use crate::ctx::{Account, Ctx};
use crate::files::{AccountEntry, DataDir};
use crate::store::StoreKey;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// The standard streams of one run.
pub struct Io {
    /// Lines of standard input (without the line end); the closed channel is the end of input.
    pub input: mpsc::UnboundedReceiver<String>,
    /// One line for standard output.
    pub out: Rc<dyn Fn(&str)>,
    /// One line for standard error (Corvus shows these to the user).
    pub err: Rc<dyn Fn(&str)>,
    /// Stop on SIGTERM / SIGINT / SIGHUP: for a process of its own, never inside an app.
    pub signals: bool,
}

/// What code deep inside a run needs of it: the error stream and a way to end the run.
struct Host {
    err: Rc<dyn Fn(&str)>,
    exit: mpsc::UnboundedSender<u8>,
}

thread_local! {
    // A run lives on one thread (current-thread runtime), so this is per run.
    static HOST: RefCell<Option<Host>> = const { RefCell::new(None) };
}

const SUCCESS: u8 = 0;
const FAILURE: u8 = 1;

#[derive(Debug, Default, PartialEq)]
struct Args {
    config: Option<PathBuf>,
    store_key_stdin: bool,
    tls_proxy: Option<String>,
    account: Option<String>,
    command: Command,
}

#[derive(Debug, Default, PartialEq)]
enum Command {
    #[default]
    None,
    Version,
    ListAccounts,
    Link {
        name: Option<String>,
    },
    JsonRpc,
    DeleteLocalAccountData,
}

fn parse_args(argv: impl IntoIterator<Item = String>) -> Result<Args, String> {
    let mut args = Args::default();
    let mut it = argv.into_iter();
    let value = |it: &mut dyn Iterator<Item = String>, opt: &str| {
        it.next().ok_or_else(|| format!("{opt} needs a value"))
    };
    while let Some(arg) = it.next() {
        if args.command == Command::None {
            match arg.as_str() {
                "-v" | "--version" => args.command = Command::Version,
                "--config" | "-c" => args.config = Some(PathBuf::from(value(&mut it, &arg)?)),
                "--store-key-stdin" => args.store_key_stdin = true,
                "--tls-proxy" => args.tls_proxy = Some(value(&mut it, &arg)?),
                "-a" | "--account" | "-u" | "--username" => args.account = Some(value(&mut it, &arg)?),
                "-o" | "--output" => {
                    let o = value(&mut it, &arg)?;
                    if o != "json" && o != "plain-text" {
                        return Err(format!("unsupported output format: {o}"));
                    }
                }
                "listAccounts" => args.command = Command::ListAccounts,
                "link" => args.command = Command::Link { name: None },
                "jsonRpc" => args.command = Command::JsonRpc,
                "deleteLocalAccountData" => args.command = Command::DeleteLocalAccountData,
                _ if arg.starts_with("--config=") => {
                    args.config = Some(PathBuf::from(&arg["--config=".len()..]))
                }
                _ if arg.starts_with("--tls-proxy=") => {
                    args.tls_proxy = Some(arg["--tls-proxy=".len()..].to_owned())
                }
                _ => return Err(format!("unknown argument: {arg}")),
            }
        } else {
            match (&mut args.command, arg.as_str()) {
                (Command::Link { name }, "-n" | "--name") => *name = Some(value(&mut it, &arg)?),
                (Command::DeleteLocalAccountData, "--ignore-registered") => {}
                (Command::JsonRpc, "--receive-mode") => {
                    let _ = value(&mut it, &arg)?;
                }
                (Command::JsonRpc, "--send-read-receipts" | "--ignore-attachments" | "--ignore-stories") => {}
                (_, "-v" | "--version") => args.command = Command::Version,
                _ => return Err(format!("unknown argument: {arg}")),
            }
        }
    }
    Ok(args)
}

/// Runs one command line (the arguments after the program name) and returns its exit code.
pub fn run(argv: Vec<String>, io: Io) -> u8 {
    let Io { input, out, err, signals } = io;
    let args = match parse_args(argv) {
        Ok(a) => a,
        Err(e) => {
            err(&format!("corvus-signal: {e}"));
            return 2;
        }
    };
    let dir = DataDir::new(args.config.clone().unwrap_or_else(DataDir::default_root));
    match args.command {
        Command::Version => {
            out(&format!("corvus-signal {VERSION}"));
            SUCCESS
        }
        Command::None => {
            err("usage: corvus-signal [--config DIR] [--store-key-stdin] [--tls-proxy HOST] \
                 (--version | -o json listAccounts | link -n NAME | -a ACCOUNT jsonRpc | \
                 -a ACCOUNT deleteLocalAccountData [--ignore-registered])");
            2
        }
        Command::ListAccounts => {
            let accounts: Vec<serde_json::Value> = dir
                .read_accounts()
                .into_iter()
                .map(|a| serde_json::json!({"number": a.number, "uuid": a.uuid}))
                .collect();
            out(&serde_json::Value::Array(accounts).to_string());
            SUCCESS
        }
        Command::DeleteLocalAccountData => delete_local_data(&dir, args.account.as_deref(), &*err),
        Command::Link { name } => {
            if let Err(e) = dir.ensure() {
                err(&format!("corvus-signal: cannot create {}: {e}", dir.root().display()));
                return FAILURE;
            }
            logging::init(&dir.log_file());
            if let Err(e) = tls_proxy::configure(args.tls_proxy.as_deref()) {
                err(&e);
                return FAILURE;
            }
            let name = name.unwrap_or_else(|| "corvus".to_owned());
            run_local(&err, link(dir, args.store_key_stdin, name, input, out.clone(), err.clone()))
        }
        Command::JsonRpc => {
            if let Err(e) = dir.ensure() {
                err(&format!("corvus-signal: cannot create {}: {e}", dir.root().display()));
                return FAILURE;
            }
            logging::init(&dir.log_file());
            if let Err(e) = tls_proxy::configure(args.tls_proxy.as_deref()) {
                err(&e);
                return FAILURE;
            }
            let (exit_tx, exit_rx) = mpsc::unbounded_channel();
            HOST.with(|h| *h.borrow_mut() = Some(Host { err: err.clone(), exit: exit_tx }));
            let code = run_local(&err, json_rpc(dir, args.store_key_stdin, args.account, input, out, exit_rx, signals));
            HOST.with(|h| *h.borrow_mut() = None);
            code
        }
    }
}

fn run_local(err: &Rc<dyn Fn(&str)>, fut: impl std::future::Future<Output = u8>) -> u8 {
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(r) => r,
        Err(e) => {
            err(&format!("corvus-signal: {e}"));
            return FAILURE;
        }
    };
    let local = tokio::task::LocalSet::new();
    local.block_on(&runtime, fut)
}

/// The store key: the first line of standard input.
async fn read_key_line(enabled: bool, input: &mut mpsc::UnboundedReceiver<String>) -> Result<Option<StoreKey>, String> {
    if !enabled {
        return Ok(None);
    }
    let line = input.recv().await.ok_or("cannot read the store key: no input")?;
    StoreKey::parse(&line).map(Some)
}

async fn link(
    dir: DataDir,
    key_from_stdin: bool,
    name: String,
    mut input: mpsc::UnboundedReceiver<String>,
    out: Rc<dyn Fn(&str)>,
    err: Rc<dyn Fn(&str)>,
) -> u8 {
    let key = match read_key_line(key_from_stdin, &mut input).await {
        Ok(k) => k,
        Err(e) => {
            err(&format!("corvus-signal: {e}"));
            return FAILURE;
        }
    };
    let path = dir.linking_store();
    files::remove_store_files(&path);
    let store = match store::open(&path, key.as_ref()).await {
        Ok(s) => s,
        Err(e) => {
            err(&format!("corvus-signal: cannot open the store: {e}"));
            return FAILURE;
        }
    };
    let (tx, rx) = oneshot::channel();
    {
        let out = out.clone();
        tokio::task::spawn_local(async move {
            if let Ok(url) = rx.await {
                out(&format!("{url}"));
            }
        });
    }
    tracing::info!("linking");
    // The end of the input cancels linking (a process is simply terminated; a run inside the app is not).
    let cancelled = async {
        while input.recv().await.is_some() {}
    };
    let result = tokio::select! {
        r = Manager::link_secondary_device(store.clone(), SignalServers::Production, name, tx) => r,
        _ = cancelled => {
            tracing::info!("linking cancelled");
            store.close().await;
            files::remove_store_files(&path);
            return FAILURE;
        }
    };
    match result {
        Ok(mut manager) => {
            let entry = {
                let data = manager.registration_data();
                AccountEntry {
                    number: data.phone_number.to_string(),
                    uuid: data.service_ids.aci.to_string(),
                    device_id: u32::from(manager.device_id()),
                }
            };
            // Ask the primary device for the contact list; it arrives on the next receive.
            if let Err(error) = manager.request_contacts().await {
                tracing::warn!(%error, "contacts sync request failed");
            }
            store.close().await;
            if let Err(e) = files::rename_store_files(&path, &dir.store()) {
                err(&format!("corvus-signal: cannot move the new store into place: {e}"));
                return FAILURE;
            }
            let uuid = entry.uuid.clone();
            if let Err(e) = dir.write_accounts(&[entry]) {
                err(&format!("corvus-signal: cannot write accounts.json: {e}"));
                return FAILURE;
            }
            tracing::info!("linked");
            out(&format!("Associated with: {uuid}"));
            SUCCESS
        }
        Err(e) => {
            tracing::warn!(error = %e, "linking failed");
            store.close().await;
            files::remove_store_files(&path);
            err(&format!("Linking failed: {e}"));
            FAILURE
        }
    }
}

fn delete_local_data(dir: &DataDir, account: Option<&str>, err: &dyn Fn(&str)) -> u8 {
    let accounts = dir.read_accounts();
    if let Some(account) = account {
        if !accounts.is_empty() && !accounts.iter().any(|a| a.number == account || a.uuid == account) {
            err(&format!("corvus-signal: account {account} is not known here"));
            return FAILURE;
        }
    }
    files::remove_store_files(&dir.store());
    files::remove_store_files(&dir.linking_store());
    for sub in [dir.attachments(), dir.avatars(), dir.stickers()] {
        if let Err(e) = std::fs::remove_dir_all(&sub) {
            if e.kind() != std::io::ErrorKind::NotFound {
                err(&format!("corvus-signal: cannot remove {}: {e}", sub.display()));
                return FAILURE;
            }
        }
    }
    let _ = std::fs::remove_file(dir.accounts_file());
    let _ = std::fs::remove_file(dir.log_file());
    let _ = std::fs::remove_file(dir.log_file().with_extension("log.1"));
    SUCCESS
}

/// Opens the account for jsonRpc, or explains why there is none.
async fn open_account(dir: &DataDir, key: Option<&StoreKey>, wanted: Option<&str>) -> Result<Account, String> {
    let path = dir.store();
    if !path.exists() {
        return Err("No account is linked yet: link this device first".into());
    }
    let store = store::open(&path, key)
        .await
        .map_err(|e| format!("Cannot open the account store (wrong key?): {e}"))?;
    let registered = store.is_registered().await;
    if !registered {
        store.close().await;
        return Err("No account is linked yet: link this device first".into());
    }
    let manager = match Manager::load_registered(store.clone()).await {
        Ok(m) => m,
        Err(e) => {
            store.close().await;
            return Err(format!("Cannot load the account: {e}"));
        }
    };
    let account = Account::new(store, manager);
    if let Some(wanted) = wanted {
        if wanted != account.number && wanted != account.aci.to_string() {
            account.store.close().await;
            return Err(format!("Account {wanted} is not linked on this device"));
        }
    }
    Ok(account)
}

async fn json_rpc(
    dir: DataDir,
    key_from_stdin: bool,
    wanted: Option<String>,
    mut input: mpsc::UnboundedReceiver<String>,
    out: Rc<dyn Fn(&str)>,
    mut exit: mpsc::UnboundedReceiver<u8>,
    signals: bool,
) -> u8 {
    let mut key = None;
    if key_from_stdin {
        match input.recv().await {
            Some(line) => match StoreKey::parse(&line) {
                Ok(k) => key = Some(k),
                Err(e) => tracing::warn!(error = %e, "invalid store key"),
            },
            None => tracing::warn!("cannot read the store key: no input"),
        }
    }
    let (out, writer) = rpc::Output::spawn(rpc::LineWriter::new(out));
    let ctx = if key_from_stdin && key.is_none() {
        Ctx::unlinked(dir, out, "No valid store key was given on stdin")
    } else {
        match open_account(&dir, key.as_ref(), wanted.as_deref()).await {
            Ok(account) => {
                tracing::info!(device = account.device_id, "account opened");
                Ctx::linked(dir, out, account)
            }
            Err(reason) => {
                tracing::info!("no account: {}", logging::mask_numbers(&reason));
                Ctx::unlinked(dir, out, reason)
            }
        }
    };
    let ctx = Rc::new(ctx);
    let dispatcher = Rc::new(methods::dispatcher());

    if ctx.has_account() {
        tokio::task::spawn_local(receive::run(ctx.clone()));
    }
    if signals {
        tokio::task::spawn_local(async move {
            wait_for_termination().await;
            tracing::info!("terminated");
            HOST.with(|h| {
                if let Some(h) = h.borrow().as_ref() {
                    let _ = h.exit.send(SUCCESS);
                }
            });
        });
    }

    let code = loop {
        tokio::select! {
            line = input.recv() => match line {
                Some(line) => {
                    if let Some(incoming) = rpc::parse_line(&line) {
                        rpc::handle_incoming(&ctx, &dispatcher, incoming);
                    }
                }
                None => {
                    tracing::info!("stdin closed");
                    // let responses already computed reach stdout
                    tokio::task::yield_now().await;
                    break SUCCESS;
                }
            },
            code = exit.recv() => break code.unwrap_or(SUCCESS),
        }
    };
    drop(writer);
    methods::calls::shutdown().await;
    if let Ok(account) = ctx.account() {
        account.store.close().await;
    }
    code
}

async fn wait_for_termination() {
    use tokio::signal::unix::{SignalKind, signal};
    let (Ok(mut term), Ok(mut int), Ok(mut hup)) = (
        signal(SignalKind::terminate()),
        signal(SignalKind::interrupt()),
        signal(SignalKind::hangup()),
    ) else {
        return futures::future::pending().await;
    };
    tokio::select! {
        _ = term.recv() => {}
        _ = int.recv() => {}
        _ = hup.recv() => {}
    }
}

/// Fatal account error while running: one line on stderr (Corvus shows it), then the run ends with
/// exit code 3. Never returns: the task that called it is dropped with the run.
pub async fn shutdown_with_error(_account: &Account, message: &str) -> ! {
    HOST.with(|h| {
        if let Some(h) = h.borrow().as_ref() {
            (h.err)(message);
            let _ = h.exit.send(3);
        }
    });
    futures::future::pending::<()>().await;
    unreachable!()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(s: &str) -> Result<Args, String> {
        parse_args(s.split_whitespace().map(str::to_owned))
    }

    #[test]
    fn corvus_invocations() {
        assert_eq!(parse("--version").unwrap().command, Command::Version);
        let a = parse("--tls-proxy proxy.example:443 -o json listAccounts").unwrap();
        assert_eq!(a.command, Command::ListAccounts);
        assert_eq!(a.tls_proxy.as_deref(), Some("proxy.example:443"));
        let a = parse("--config /tmp/x --store-key-stdin -a +15550000000 jsonRpc").unwrap();
        assert_eq!(a.command, Command::JsonRpc);
        assert!(a.store_key_stdin);
        assert_eq!(a.account.as_deref(), Some("+15550000000"));
        assert_eq!(a.config, Some(PathBuf::from("/tmp/x")));
        let a = parse("link -n corvus").unwrap();
        assert_eq!(a.command, Command::Link { name: Some("corvus".into()) });
        let a = parse("-a +1555 deleteLocalAccountData --ignore-registered").unwrap();
        assert_eq!(a.command, Command::DeleteLocalAccountData);
        assert!(parse("bogus").is_err());
        assert!(parse("jsonRpc --nope").is_err());
        assert!(parse("--config").is_err());
    }
}
