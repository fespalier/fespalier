//! What the commands write to stdout (since 0.23.1), through [`out!`] and [`outln!`] (defined in
//! `main.rs`, so every module has them) instead of `print!` and `println!`, which `clippy.toml`
//! refuses.
//!
//! A reader that stops early (`fsp routes --json | head -1`) closes the pipe, and `println!`
//! panics on the next write ("failed printing to stdout: Broken pipe", exit 101). Here a closed
//! pipe ends the output: what is left is dropped, and the command goes on to its own exit code, so
//! `fsp check --json | head -1` still fails on an error. Rust ignores SIGPIPE on Unix, so a write to
//! a closed pipe returns `EPIPE` on Linux and macOS, and Windows' `ERROR_BROKEN_PIPE` and
//! `ERROR_NO_DATA` read as the same [`io::ErrorKind::BrokenPipe`].

use std::fmt;
use std::io::{self, Write};

/// `print!`: writes `args` to stdout.
///
/// # Panics
///
/// When stdout fails for another reason than a closed pipe, as `print!` does.
pub fn write(args: fmt::Arguments<'_>) {
    settle(io::stdout().lock().write_fmt(args));
}

/// `println!`: writes `args` and a newline to stdout.
///
/// # Panics
///
/// When stdout fails for another reason than a closed pipe, as `println!` does.
pub fn line(args: fmt::Arguments<'_>) {
    let mut out = io::stdout().lock();
    settle(out.write_fmt(args).and_then(|()| out.write_all(b"\n")));
}

/// A closed pipe is the end of the output; any other failure stops `fsp` as `println!` does.
fn settle(result: io::Result<()>) {
    if let Err(e) = result
        && e.kind() != io::ErrorKind::BrokenPipe
    {
        panic!("failed printing to stdout: {e}");
    }
}
