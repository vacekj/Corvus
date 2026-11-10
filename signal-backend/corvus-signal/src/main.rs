//! corvus-signal: Corvus's Signal backend (replaces signal-cli). See DESIGN.md.

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

use std::io::Write as _;
use std::path::PathBuf;
use std::process::ExitCode;
use std::rc::Rc;

use futures::channel::oneshot;
use presage::Manager;
use presage::libsignal_service::configuration::SignalServers;
use presage::store::StateStore;
use tokio::io::{AsyncBufReadExt, BufReader};

use crate::ctx::{Account, Ctx};
use crate::files::{AccountEntry, DataDir};
use crate::store::StoreKey;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

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

fn main() -> ExitCode {
    let args = match parse_args(std::env::args().skip(1)) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("corvus-signal: {e}");
            return ExitCode::from(2);
        }
    };
    let dir = DataDir::new(args.config.clone().unwrap_or_else(DataDir::default_root));
    match args.command {
        Command::Version => {
            println!("corvus-signal {VERSION}");
            ExitCode::SUCCESS
        }
        Command::None => {
            eprintln!(
                "usage: corvus-signal [--config DIR] [--store-key-stdin] [--tls-proxy HOST] \
                 (--version | -o json listAccounts | link -n NAME | -a ACCOUNT jsonRpc | \
                 -a ACCOUNT deleteLocalAccountData [--ignore-registered])"
            );
            ExitCode::from(2)
        }
        Command::ListAccounts => {
            let accounts: Vec<serde_json::Value> = dir
                .read_accounts()
                .into_iter()
                .map(|a| serde_json::json!({"number": a.number, "uuid": a.uuid}))
                .collect();
            println!("{}", serde_json::Value::Array(accounts));
            ExitCode::SUCCESS
        }
        Command::DeleteLocalAccountData => delete_local_data(&dir, args.account.as_deref()),
        Command::Link { name } => {
            if let Err(e) = dir.ensure() {
                eprintln!("corvus-signal: cannot create {}: {e}", dir.root().display());
                return ExitCode::FAILURE;
            }
            logging::init(&dir.log_file());
            if let Err(e) = tls_proxy::configure(args.tls_proxy.as_deref()) {
                eprintln!("{e}");
                return ExitCode::FAILURE;
            }
            let key = match read_key_line(args.store_key_stdin) {
                Ok(k) => k,
                Err(e) => {
                    eprintln!("corvus-signal: {e}");
                    return ExitCode::FAILURE;
                }
            };
            let name = name.unwrap_or_else(|| "corvus".to_owned());
            run_local(link(dir, key, name))
        }
        Command::JsonRpc => {
            if let Err(e) = dir.ensure() {
                eprintln!("corvus-signal: cannot create {}: {e}", dir.root().display());
                return ExitCode::FAILURE;
            }
            logging::init(&dir.log_file());
            if let Err(e) = tls_proxy::configure(args.tls_proxy.as_deref()) {
                eprintln!("{e}");
                return ExitCode::FAILURE;
            }
            run_local(json_rpc(dir, args.store_key_stdin, args.account))
        }
    }
}

fn run_local(fut: impl std::future::Future<Output = ExitCode>) -> ExitCode {
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("corvus-signal: {e}");
            return ExitCode::FAILURE;
        }
    };
    let local = tokio::task::LocalSet::new();
    local.block_on(&runtime, fut)
}

/// Reads the store key from the first stdin line (blocking; used before the runtime reads stdin).
fn read_key_line(enabled: bool) -> Result<Option<StoreKey>, String> {
    if !enabled {
        return Ok(None);
    }
    let mut line = String::new();
    std::io::stdin()
        .read_line(&mut line)
        .map_err(|e| format!("cannot read the store key: {e}"))?;
    StoreKey::parse(&line).map(Some)
}

async fn link(dir: DataDir, key: Option<StoreKey>, name: String) -> ExitCode {
    let path = dir.linking_store();
    files::remove_store_files(&path);
    let store = match store::open(&path, key.as_ref()).await {
        Ok(s) => s,
        Err(e) => {
            eprintln!("corvus-signal: cannot open the store: {e}");
            return ExitCode::FAILURE;
        }
    };
    let (tx, rx) = oneshot::channel();
    tokio::task::spawn_local(async move {
        if let Ok(url) = rx.await {
            let mut out = std::io::stdout().lock();
            let _ = writeln!(out, "{url}");
            let _ = out.flush();
        }
    });
    tracing::info!("linking");
    let result = Manager::link_secondary_device(store.clone(), SignalServers::Production, name, tx).await;
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
                eprintln!("corvus-signal: cannot move the new store into place: {e}");
                return ExitCode::FAILURE;
            }
            let uuid = entry.uuid.clone();
            if let Err(e) = dir.write_accounts(&[entry]) {
                eprintln!("corvus-signal: cannot write accounts.json: {e}");
                return ExitCode::FAILURE;
            }
            tracing::info!("linked");
            println!("Associated with: {uuid}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            tracing::warn!(error = %e, "linking failed");
            store.close().await;
            files::remove_store_files(&path);
            eprintln!("Linking failed: {e}");
            ExitCode::FAILURE
        }
    }
}

fn delete_local_data(dir: &DataDir, account: Option<&str>) -> ExitCode {
    let accounts = dir.read_accounts();
    if let Some(account) = account {
        if !accounts.is_empty() && !accounts.iter().any(|a| a.number == account || a.uuid == account) {
            eprintln!("corvus-signal: account {account} is not known here");
            return ExitCode::FAILURE;
        }
    }
    files::remove_store_files(&dir.store());
    files::remove_store_files(&dir.linking_store());
    for sub in [dir.attachments(), dir.avatars(), dir.stickers()] {
        if let Err(e) = std::fs::remove_dir_all(&sub) {
            if e.kind() != std::io::ErrorKind::NotFound {
                eprintln!("corvus-signal: cannot remove {}: {e}", sub.display());
                return ExitCode::FAILURE;
            }
        }
    }
    let _ = std::fs::remove_file(dir.accounts_file());
    let _ = std::fs::remove_file(dir.log_file());
    let _ = std::fs::remove_file(dir.log_file().with_extension("log.1"));
    ExitCode::SUCCESS
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

async fn json_rpc(dir: DataDir, key_from_stdin: bool, wanted: Option<String>) -> ExitCode {
    let mut stdin = BufReader::new(tokio::io::stdin());
    let mut key = None;
    if key_from_stdin {
        let mut line = String::new();
        match stdin.read_line(&mut line).await {
            Ok(_) => match StoreKey::parse(&line) {
                Ok(k) => key = Some(k),
                Err(e) => tracing::warn!(error = %e, "invalid store key"),
            },
            Err(error) => tracing::warn!(%error, "cannot read the store key"),
        }
    }
    let (out, writer) = rpc::Output::spawn(tokio::io::stdout());
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
    {
        let ctx = ctx.clone();
        tokio::task::spawn_local(async move {
            wait_for_termination().await;
            tracing::info!("terminated");
            shutdown(&ctx, 0).await;
        });
    }

    let mut line = String::new();
    loop {
        line.clear();
        match stdin.read_line(&mut line).await {
            Ok(0) => break,
            Ok(_) => {
                if let Some(incoming) = rpc::parse_line(&line) {
                    rpc::handle_incoming(&ctx, &dispatcher, incoming);
                }
            }
            Err(error) => {
                tracing::warn!(%error, "stdin read failed");
                break;
            }
        }
    }
    tracing::info!("stdin closed");
    // let responses already computed reach stdout
    tokio::task::yield_now().await;
    drop(writer);
    shutdown(&ctx, 0).await
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

async fn shutdown(ctx: &Ctx, code: i32) -> ! {
    methods::calls::shutdown().await;
    if let Ok(account) = ctx.account() {
        account.store.close().await;
    }
    std::process::exit(code)
}

/// Fatal account error while running: one line on stderr (Corvus shows it), then exit.
pub async fn shutdown_with_error(account: &Account, message: &str) -> ! {
    eprintln!("{message}");
    account.store.close().await;
    std::process::exit(3)
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
