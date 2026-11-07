//! `orders-demo-server --listen 127.0.0.1:0 [--audience NAME] [--attestation-ttl-secs N]
//! [--clock-skew-secs N] [--issuer-seed-hex 64HEX] [--test-hooks]`
//!
//! Prints one JSON line on stdout once it is listening, then serves until killed:
//! `{"addr":"127.0.0.1:PORT","audience":"...","issuer_jwk":{...},"test_hooks":false}`.

use std::process::ExitCode;

use cratestack::serde_json::json;
use orders_demo_server::{Config, build};

struct Args {
    listen: String,
    config: Config,
}

fn seconds(flag: &str, value: &str) -> Result<u64, String> {
    value
        .parse()
        .map_err(|_| format!("{flag} is a number of seconds"))
}

fn parse() -> Result<Args, String> {
    let mut args = Args {
        listen: "127.0.0.1:0".to_owned(),
        config: Config::default(),
    };
    let mut rest = std::env::args().skip(1);
    while let Some(flag) = rest.next() {
        if flag == "--test-hooks" {
            args.config.test_hooks = true;
            continue;
        }
        let value = rest.next().ok_or(format!("{flag} needs a value"))?;
        match flag.as_str() {
            "--listen" => args.listen = value,
            "--audience" => args.config.audience = value,
            "--attestation-ttl-secs" => {
                args.config.attestation_ttl_secs = seconds(&flag, &value)?;
            }
            "--clock-skew-secs" => args.config.clock_skew_secs = seconds(&flag, &value)?,
            "--issuer-seed-hex" => args.config.issuer_seed = Some(seed_from_hex(&value)?),
            other => return Err(format!("unknown flag {other}")),
        }
    }
    Ok(args)
}

fn seed_from_hex(text: &str) -> Result<[u8; 32], String> {
    let bytes = (0..text.len())
        .step_by(2)
        .map(|at| {
            text.get(at..at + 2)
                .and_then(|pair| u8::from_str_radix(pair, 16).ok())
        })
        .collect::<Option<Vec<u8>>>();
    bytes
        .and_then(|bytes| <[u8; 32]>::try_from(bytes).ok())
        .ok_or_else(|| "--issuer-seed-hex is 64 hex digits".to_owned())
}

async fn run() -> Result<(), String> {
    let args = parse()?;
    let built = build(&args.config)
        .await
        .map_err(|error| error.to_string())?;
    let listener = tokio::net::TcpListener::bind(&args.listen)
        .await
        .map_err(|error| format!("cannot listen on {}: {error}", args.listen))?;
    let addr = listener.local_addr().map_err(|error| error.to_string())?;
    println!(
        "{}",
        json!({
            "addr": addr.to_string(),
            "audience": built.hello.audience,
            "issuer_jwk": built.hello.issuer_jwk,
            "test_hooks": args.config.test_hooks,
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
            eprintln!("orders-demo-server: {message}");
            ExitCode::FAILURE
        }
    }
}
