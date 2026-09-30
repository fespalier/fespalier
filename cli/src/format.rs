//! Optional `dart format` of the generated file (`--format`, or `format: true`
//! in pubspec.yaml). The code goes through `dart format` on stdin, so nothing
//! is written until the formatted text is known: `gen` compares it with the file
//! on disk, and a formatted file that is already up to date stays "unchanged".
//! `--stdin-name` points at the output path, so the formatter finds the
//! project's package config (language version) and `analysis_options.yaml`
//! (`formatter: page_width`), exactly as `dart format lib/` would.

use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

/// The formatted code, or the code unchanged plus a warning when `dart` is
/// missing or refuses the input.
pub fn format_dart(code: &str, output: &Path) -> (String, Option<String>) {
    match run(code, output) {
        Ok(formatted) => (formatted, None),
        Err(why) => (
            code.to_string(),
            Some(format!(
                "warning: not formatting {}: {why}",
                output.display()
            )),
        ),
    }
}

fn run(code: &str, output: &Path) -> Result<String, String> {
    let mut child = Command::new(dart_program())
        .arg("format")
        .arg(format!("--stdin-name={}", output.display()))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                "`dart` is not on PATH".to_string()
            } else {
                format!("could not run `dart format`: {e}")
            }
        })?;
    // Feed stdin from a thread: a large file could fill the pipes both ways.
    let mut stdin = child.stdin.take().ok_or("no stdin")?;
    let input = code.to_string();
    let feeder = std::thread::spawn(move || stdin.write_all(input.as_bytes()));
    let out = child
        .wait_with_output()
        .map_err(|e| format!("`dart format` failed: {e}"))?;
    let _ = feeder.join();
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(format!(
            "`dart format` failed: {}",
            err.lines().next().unwrap_or("").trim()
        ));
    }
    String::from_utf8(out.stdout).map_err(|_| "`dart format` printed invalid UTF-8".to_string())
}

/// `dart`, or `FSP_DART` (tests, unusual installs).
fn dart_program() -> String {
    std::env::var("FSP_DART").unwrap_or_else(|_| "dart".into())
}
