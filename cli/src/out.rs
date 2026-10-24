//! What the commands write to stdout (since 0.23.1), through [`out!`] and [`outln!`], and to
//! stderr, through [`err!`] and [`errln!`] (defined in `main.rs`, so every module has them),
//! instead of `print!`, `println!`, `eprint!` and `eprintln!`, which `clippy.toml` refuses.
//!
//! A reader that stops early (`fsp routes --json | head -1`, or `fsp check 2>&1 | head -1`, since
//! `gen` and `check` write to stderr) closes the pipe, and `println!` panics on the next write
//! ("failed printing to stdout: Broken pipe", exit 101). Here a closed pipe ends the output: what
//! is left is dropped, and the command goes on to its own exit code, so `fsp check --json | head -1`
//! still fails on an error. Rust ignores SIGPIPE on Unix, so a write to a closed pipe returns
//! `EPIPE` on Linux and macOS, and Windows' `ERROR_BROKEN_PIPE` and `ERROR_NO_DATA` read as the
//! same [`io::ErrorKind::BrokenPipe`].
//!
//! `fsp dev`'s full-screen view prints through neither: while it is up nothing may write to
//! stdout or stderr, so a message goes into a pane.

use std::fmt;

/// `print!`: writes `args` to stdout.
///
/// # Panics
///
/// When stdout fails for another reason than a closed pipe, as `print!` does.
pub fn write(args: fmt::Arguments<'_>) {
    put(Stream::Out, args, false);
}

/// `println!`: writes `args` and a newline to stdout.
///
/// # Panics
///
/// When stdout fails for another reason than a closed pipe, as `println!` does.
pub fn line(args: fmt::Arguments<'_>) {
    put(Stream::Out, args, true);
}

/// `eprint!`: writes `args` to stderr.
///
/// # Panics
///
/// When stderr fails for another reason than a closed pipe, as `eprint!` does.
pub fn err(args: fmt::Arguments<'_>) {
    put(Stream::Err, args, false);
}

/// `eprintln!`: writes `args` and a newline to stderr.
///
/// # Panics
///
/// When stderr fails for another reason than a closed pipe, as `eprintln!` does.
pub fn errln(args: fmt::Arguments<'_>) {
    put(Stream::Err, args, true);
}

#[derive(Clone, Copy)]
enum Stream {
    Out,
    Err,
}

/// One write, under one lock. A closed pipe is the end of the output; any other failure stops
/// `fsp` as `println!` does.
#[cfg(not(test))]
fn put(stream: Stream, args: fmt::Arguments<'_>, newline: bool) {
    use std::io::{self, Write};
    fn to(out: &mut impl Write, args: fmt::Arguments<'_>, newline: bool) -> io::Result<()> {
        out.write_fmt(args)?;
        if newline {
            out.write_all(b"\n")
        } else {
            Ok(())
        }
    }
    let (result, name) = match stream {
        Stream::Out => (to(&mut io::stdout().lock(), args, newline), "stdout"),
        Stream::Err => (to(&mut io::stderr().lock(), args, newline), "stderr"),
    };
    if let Err(e) = result
        && e.kind() != io::ErrorKind::BrokenPipe
    {
        panic!("failed printing to {name}: {e}");
    }
}

/// In a unit test the macros libtest captures, so that a passing test is silent as it is with
/// `print!` (it captures those, and not `io::stdout()`). The closed pipe is tested by running
/// `fsp` (`tests/cli.rs`).
#[cfg(test)]
#[allow(
    clippy::disallowed_macros,
    reason = "libtest captures print! and eprint!, not io::stdout() and io::stderr()"
)]
fn put(stream: Stream, args: fmt::Arguments<'_>, newline: bool) {
    match (stream, newline) {
        (Stream::Out, false) => print!("{args}"),
        (Stream::Out, true) => println!("{args}"),
        (Stream::Err, false) => eprint!("{args}"),
        (Stream::Err, true) => eprintln!("{args}"),
    }
}

#[cfg(test)]
mod tests {
    /// `outln!()` and `errln!()` with no arguments compile, as `println!()` and `eprintln!()` do
    /// (they are matched here, not run: the output would go to the test run's own).
    #[test]
    fn an_empty_line_compiles() {
        fn never() {
            outln!();
            errln!();
            out!("{}", 1);
            err!("{}", 2);
        }
        let _ = never;
    }
}
