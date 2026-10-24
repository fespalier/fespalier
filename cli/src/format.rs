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
    format_with(code, output, None)
}

/// [`format_dart`] at a stated language version (`"3.9"`), for code that is not in a package yet:
/// a file written to a temporary folder has no package config, so the formatter would take the
/// newest language its `dart` knows, and a layout that changed since (Dart 3.13 hugs a long string
/// argument in a trailing closure) would pass here and fail in the app that is made with `sdk: ^3.9.0`.
#[cfg(test)]
pub fn format_dart_at(
    code: &str,
    output: &Path,
    language_version: &str,
) -> (String, Option<String>) {
    format_with(code, output, Some(language_version))
}

fn format_with(
    code: &str,
    output: &Path,
    language_version: Option<&str>,
) -> (String, Option<String>) {
    match run(code, output, language_version) {
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

fn run(code: &str, output: &Path, language_version: Option<&str>) -> Result<String, String> {
    let mut command = Command::new(dart_program());
    command
        .arg("format")
        .arg(format!("--stdin-name={}", output.display()));
    if let Some(version) = language_version {
        command.arg(format!("--language-version={version}"));
    }
    let mut child = command
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
pub fn dart_program() -> String {
    std::env::var("FSP_DART").unwrap_or_else(|_| "dart".into())
}
