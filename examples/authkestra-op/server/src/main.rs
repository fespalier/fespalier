//! `authkestra-op-demo-server [--listen 127.0.0.1:0] [--api-listen 127.0.0.1:0]`
//!
//! Binds the OP and the API, then prints one JSON line on stdout and serves until killed:
//! `{"issuer":"http://127.0.0.1:P","api":"http://127.0.0.1:Q","client_id":"...","redirect_uri":"...","username":"ada","password":"ada"}`.
//! The issuer is the address the OP was bound to, so port 0 works: discovery is checked
//! against it.

use std::process::ExitCode;

use authkestra_op_demo_server::{CLIENT_ID, PASSWORD, REDIRECT_URI, USERNAME, build};
use tokio::net::TcpListener;

struct Args {
    listen: String,
    api_listen: String,
}

fn parse() -> Result<Args, String> {
    let mut args = Args {
        listen: "127.0.0.1:0".to_owned(),
        api_listen: "127.0.0.1:0".to_owned(),
    };
    let mut rest = std::env::args().skip(1);
    while let Some(flag) = rest.next() {
        let mut value = || rest.next().ok_or(format!("{flag} needs a value"));
        match flag.as_str() {
            "--listen" => args.listen = value()?,
            "--api-listen" => args.api_listen = value()?,
            other => return Err(format!("unknown flag {other}")),
        }
    }
    Ok(args)
}

async fn bind(address: &str) -> Result<(TcpListener, String), String> {
    let listener = TcpListener::bind(address)
        .await
        .map_err(|error| format!("cannot listen on {address}: {error}"))?;
    let local = listener.local_addr().map_err(|error| error.to_string())?;
    Ok((listener, format!("http://{local}")))
}

async fn run() -> Result<(), String> {
    let args = parse()?;
    let (op_listener, issuer) = bind(&args.listen).await?;
    let (api_listener, api) = bind(&args.api_listen).await?;
    let servers = build(&issuer, &api).await?;
    println!(
        "{}",
        serde_json::json!({
            "issuer": issuer,
            "api": api,
            "client_id": CLIENT_ID,
            "redirect_uri": REDIRECT_URI,
            "username": USERNAME,
            "password": PASSWORD,
        })
    );
    let op = axum::serve(op_listener, servers.op);
    let api = axum::serve(api_listener, servers.api);
    tokio::try_join!(op, api).map_err(|error| error.to_string())?;
    Ok(())
}

#[tokio::main]
async fn main() -> ExitCode {
    match run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("authkestra-op-demo-server: {error}");
            ExitCode::FAILURE
        }
    }
}
