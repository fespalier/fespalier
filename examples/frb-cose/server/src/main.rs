//! `frb-cose-demo-server --listen 127.0.0.1:0 [--audience NAME] [--server-scalar-hex 64HEX] [--exit-when-stdin-closes]`
//!
//! Prints one JSON line on stdout once it is listening, then serves until killed:
//! `{"addr":"127.0.0.1:PORT","server_public_jwk":{...},"audience":"..."}`.
//!
//! `--exit-when-stdin-closes` is for a program that starts the server and holds its stdin open (the end-to-end test
//! does): when that program dies, even by SIGKILL, the pipe closes and the server exits with it, so a killed run
//! leaves no server behind. It is opt-in because a server started with stdin at `/dev/null` would exit at once.

use std::process::ExitCode;

use cratestack::serde_json::json;
use frb_cose_demo_server::{DEFAULT_AUDIENCE, build, random_scalar};

struct Args {
    listen: String,
    audience: String,
    scalar: Option<String>,
    exit_when_stdin_closes: bool,
}

fn parse() -> Result<Args, String> {
    let mut args = Args {
        listen: "127.0.0.1:0".to_owned(),
        audience: DEFAULT_AUDIENCE.to_owned(),
        scalar: None,
        exit_when_stdin_closes: false,
    };
    let mut rest = std::env::args().skip(1);
    while let Some(flag) = rest.next() {
        let mut value = || rest.next().ok_or(format!("{flag} needs a value"));
        match flag.as_str() {
            "--listen" => args.listen = value()?,
            "--audience" => args.audience = value()?,
            "--server-scalar-hex" => args.scalar = Some(value()?),
            "--exit-when-stdin-closes" => args.exit_when_stdin_closes = true,
            other => return Err(format!("unknown flag {other}")),
        }
    }
    Ok(args)
}

fn scalar_from_hex(text: &str) -> Result<[u8; 32], String> {
    let bytes = (0..text.len())
        .step_by(2)
        .map(|at| {
            text.get(at..at + 2)
                .and_then(|pair| u8::from_str_radix(pair, 16).ok())
        })
        .collect::<Option<Vec<u8>>>();
    bytes
        .and_then(|bytes| <[u8; 32]>::try_from(bytes).ok())
        .ok_or_else(|| "--server-scalar-hex is 64 hex digits".to_owned())
}

async fn run() -> Result<(), String> {
    let args = parse()?;
    let scalar = match &args.scalar {
        Some(text) => scalar_from_hex(text)?,
        None => random_scalar().map_err(|error| error.to_string())?,
    };
    let built = build(&args.audience, &scalar).map_err(|error| error.to_string())?;
    let listener = tokio::net::TcpListener::bind(&args.listen)
        .await
        .map_err(|error| format!("cannot listen on {}: {error}", args.listen))?;
    let addr = listener.local_addr().map_err(|error| error.to_string())?;
    println!(
        "{}",
        json!({
            "addr": addr.to_string(),
            "server_public_jwk": built.hello.server_public_jwk,
            "audience": built.hello.audience,
        })
    );
    if args.exit_when_stdin_closes {
        std::thread::spawn(|| {
            // Reads until the end of the stream: nothing is ever sent on it, so it ends when the parent's end closes.
            let _ = std::io::copy(&mut std::io::stdin().lock(), &mut std::io::sink());
            std::process::exit(0);
        });
    }
    cratestack::axum::serve(listener, built.router.into_make_service())
        .await
        .map_err(|error| error.to_string())
}

#[tokio::main]
async fn main() -> ExitCode {
    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("frb-cose-demo-server: {message}");
            ExitCode::FAILURE
        }
    }
}
