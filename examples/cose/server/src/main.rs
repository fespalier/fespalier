//! `cose-demo-server --listen 127.0.0.1:0 [--audience NAME] [--server-scalar-hex 64HEX]`
//!
//! Prints one JSON line on stdout once it is listening, then serves until killed:
//! `{"addr":"127.0.0.1:PORT","server_public_jwk":{...},"audience":"..."}`.

use std::process::ExitCode;

use cose_demo_server::{DEFAULT_AUDIENCE, build, random_scalar};
use cratestack::serde_json::json;

struct Args {
    listen: String,
    audience: String,
    scalar: Option<String>,
}

fn parse() -> Result<Args, String> {
    let mut args = Args {
        listen: "127.0.0.1:0".to_owned(),
        audience: DEFAULT_AUDIENCE.to_owned(),
        scalar: None,
    };
    let mut rest = std::env::args().skip(1);
    while let Some(flag) = rest.next() {
        let mut value = || rest.next().ok_or(format!("{flag} needs a value"));
        match flag.as_str() {
            "--listen" => args.listen = value()?,
            "--audience" => args.audience = value()?,
            "--server-scalar-hex" => args.scalar = Some(value()?),
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
    cratestack::axum::serve(listener, built.router.into_make_service())
        .await
        .map_err(|error| error.to_string())
}

#[tokio::main]
async fn main() -> ExitCode {
    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("cose-demo-server: {message}");
            ExitCode::FAILURE
        }
    }
}
