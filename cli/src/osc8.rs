//! Clickable file locations: OSC 8 hyperlinks (since 0.9.0). A terminal that supports them turns
//! `file:line:column` into a link that opens the file; one that does not would print the escape
//! codes, so they are used only where the terminal is known to understand them.

use std::path::Path;

/// Whether to write hyperlinks. `FORCE_HYPERLINK=1` or `0` decides; else a terminal known to
/// support them: iTerm2, `WezTerm`, VS Code's, Ghostty, Hyper, Tabby, Windows Terminal, kitty, foot,
/// Alacritty, and VTE 0.50 or later. `get` reads the environment.
#[must_use]
pub fn enabled(get: impl Fn(&str) -> Option<String>) -> bool {
    if let Some(force) = get("FORCE_HYPERLINK") {
        return !matches!(force.trim(), "" | "0");
    }
    let set = |name: &str| get(name).is_some_and(|v| !v.is_empty());
    let program = get("TERM_PROGRAM").unwrap_or_default();
    let term = get("TERM").unwrap_or_default();
    [
        "iTerm.app",
        "WezTerm",
        "vscode",
        "ghostty",
        "Hyper",
        "Tabby",
    ]
    .contains(&program.as_str())
        || set("WT_SESSION")
        || set("KITTY_WINDOW_ID")
        || get("VTE_VERSION")
            .and_then(|v| v.trim().parse::<u32>().ok())
            .is_some_and(|v| v >= 5000)
        || ["xterm-kitty", "foot", "alacritty"]
            .iter()
            .any(|t| term.starts_with(t))
}

/// `enabled` over the process environment.
#[must_use]
pub fn enabled_here() -> bool {
    enabled(|k| std::env::var(k).ok())
}

/// `text` as a link to `url`.
#[must_use]
pub fn link(url: &str, text: &str) -> String {
    format!("\x1b]8;;{url}\x1b\\{text}\x1b]8;;\x1b\\")
}

/// `file://` and the absolute `path`, percent-encoded where a URL needs it.
#[must_use]
pub fn file_url(path: &Path) -> String {
    let text = path.to_string_lossy().replace('\\', "/");
    let mut url = String::from("file://");
    if !text.starts_with('/') {
        url.push('/');
    }
    for b in text.bytes() {
        if b.is_ascii_alphanumeric() || b"/-._~:".contains(&b) {
            url.push(char::from(b));
        } else {
            url.push_str(&format!("%{b:02X}"));
        }
    }
    url
}

/// `lines` with each occurrence of a location's text turned into a link to its file.
#[must_use]
pub fn link_locations(lines: Vec<String>, locations: &[(String, String)]) -> Vec<String> {
    lines
        .into_iter()
        .map(|mut line| {
            for (text, url) in locations {
                if line.contains(text.as_str()) {
                    line = line.replace(text.as_str(), &link(url, text));
                }
            }
            line
        })
        .collect()
}
