//! Prints the measurement as Markdown, for `REPORT.md`.
//!
//! The same run the tests drive, rendered instead of asserted. It exists so that the numbers in the
//! report can be re-derived by anyone with a checkout, rather than taken on trust:
//!
//! ```text
//! cargo run --release --bin wire-sizes-report > REPORT.md
//! ```
//!
//! `tests/report.rs` compares this output with the committed `REPORT.md`, so a stale report fails
//! the build rather than quietly disagreeing with the code.

#[tokio::main]
async fn main() {
    match wire_sizes_demo_server::report::generate().await {
        Ok(markdown) => print!("{markdown}"),
        Err(error) => {
            eprintln!("wire-sizes-report: {error}");
            std::process::exit(1);
        }
    }
}
