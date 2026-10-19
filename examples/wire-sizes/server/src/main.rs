//! `wire-sizes-demo-server`: one schema, served as JSON, CBOR or `COSE_Sign1` CBOR.
//!
//! ```text
//! wire-sizes-demo-server --variant json|cbor|cose --listen 127.0.0.1:0
//! ```
//!
//! It prints one JSON line when it listens, with the variant and (for `cose`) the key its answers
//! are sealed with. It then serves until killed.

use std::net::SocketAddr;

use cratestack::serde_json;
use wire_sizes_demo_server::{DEFAULT_AUDIENCE, Variant, build, random_scalar};

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("wire-sizes-demo-server: {error}");
        std::process::exit(1);
    }
}

#[derive(Debug)]
struct Args {
    listen: String,
    variant: String,
    audience: String,
}

impl Default for Args {
    fn default() -> Self {
        Self {
            listen: "127.0.0.1:0".to_owned(),
            variant: "cbor".to_owned(),
            audience: DEFAULT_AUDIENCE.to_owned(),
        }
    }
}

fn parse_args() -> Result<Args, String> {
    let mut args = Args::default();
    let mut rest = std::env::args().skip(1);
    while let Some(arg) = rest.next() {
        let mut value = || rest.next().ok_or_else(|| format!("{arg} needs a value"));
        match arg.as_str() {
            "--listen" => args.listen = value()?,
            "--variant" => args.variant = value()?,
            "--audience" => args.audience = value()?,
            "--help" | "-h" => {
                println!(
                    "wire-sizes-demo-server --variant json|cbor|cose [--listen ADDR] [--audience NAME]"
                );
                std::process::exit(0);
            }
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    Ok(args)
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let args = parse_args()?;
    let variant = Variant::parse(&args.variant)?;
    let scalar = random_scalar()?;
    let built = build(variant, &args.audience, &scalar)?;

    let listener = tokio::net::TcpListener::bind(&args.listen).await?;
    let addr: SocketAddr = listener.local_addr()?;

    // One line, so a runner can read the port and (for `cose`) the key without parsing logs.
    println!(
        "{}",
        serde_json::json!({
            "addr": addr.to_string(),
            "variant": built.hello.variant,
            "audience": built.hello.audience,
            "server_public_jwk": built.hello.server_public_jwk,
        })
    );

    cratestack::axum::serve(listener, built.router).await?;
    Ok(())
}
