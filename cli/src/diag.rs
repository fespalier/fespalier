//! File-scoped diagnostics. `Display` gives the one-line form used in tests
//! (`✗ products/$id/page.dart:4  message`); [`render`] prints them with source
//! snippets through codespan-reporting.

use std::fmt;
use std::io::IsTerminal;
use std::path::Path;

use codespan_reporting::diagnostic::{Diagnostic, Label};
use codespan_reporting::files::SimpleFiles;
use codespan_reporting::term::{
    self,
    termcolor::{ColorChoice, StandardStream},
};

use crate::dart::Span;

#[derive(Debug, Clone, PartialEq)]
pub enum Level {
    Error,
    Warning,
}

#[derive(Debug, Clone)]
pub struct Diag {
    pub level: Level,
    /// Relative to the app folder (`lib/app` by default).
    pub file: String,
    pub span: Option<Span>,
    pub msg: String,
}

#[derive(Debug, Default)]
pub struct Diags(pub Vec<Diag>);

impl Diags {
    pub fn error(&mut self, file: &str, span: Option<&Span>, msg: impl Into<String>) {
        self.push(Level::Error, file, span, msg.into());
    }

    pub fn warn(&mut self, file: &str, span: Option<&Span>, msg: impl Into<String>) {
        self.push(Level::Warning, file, span, msg.into());
    }

    fn push(&mut self, level: Level, file: &str, span: Option<&Span>, msg: String) {
        let d = Diag {
            level,
            file: file.into(),
            span: span.cloned(),
            msg,
        };
        // Inherited files can trip the same check from several routes.
        if !self
            .0
            .iter()
            .any(|x| x.file == d.file && x.msg == d.msg && x.span == d.span)
        {
            self.0.push(d);
        }
    }

    pub fn has_errors(&self) -> bool {
        self.0.iter().any(|d| d.level == Level::Error)
    }

    pub fn error_count(&self) -> usize {
        self.0.iter().filter(|d| d.level == Level::Error).count()
    }
}

impl fmt::Display for Diag {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mark = match self.level {
            Level::Error => "✗",
            Level::Warning => "!",
        };
        match &self.span {
            Some(s) => write!(f, "{mark} {}:{}  {}", self.file, s.line, self.msg),
            None => write!(f, "{mark} {}  {}", self.file, self.msg),
        }
    }
}

/// Prints diagnostics to stderr, with the offending source when there is a span.
/// `shown` is the app folder as the user spells it (`lib/app`).
pub fn render(app_dir: &Path, shown: &str, diags: &Diags) {
    let color = if std::io::stderr().is_terminal() {
        ColorChoice::Auto
    } else {
        ColorChoice::Never
    };
    let out = StandardStream::stderr(color);
    let config = term::Config::default();
    let mut files = SimpleFiles::new();
    for d in &diags.0 {
        let base = match d.level {
            Level::Error => Diagnostic::error(),
            Level::Warning => Diagnostic::warning(),
        };
        let shown = format!("{shown}/{}", d.file);
        let source = d
            .span
            .as_ref()
            .and_then(|_| std::fs::read_to_string(app_dir.join(&d.file)).ok());
        let diagnostic = match (&d.span, source) {
            (Some(span), Some(src)) => {
                let id = files.add(shown, src);
                base.with_message(&d.msg)
                    .with_labels(vec![Label::primary(id, span.bytes.clone())])
            }
            _ => base.with_message(format!("{shown}: {}", d.msg)),
        };
        if term::emit_to_write_style(&mut out.lock(), &config, &files, &diagnostic).is_err() {
            eprintln!("{d}");
        }
    }
}

/// One diagnostic as a JSON object, for editors:
/// `{"file","line","column","severity","message"}`. `file` is relative to the
/// project root (`lib/app/products/$id/page.dart`); `line` and `column` are
/// 1-based (the column counts characters) and `null` when the diagnostic isn't
/// about a place in the file.
pub fn json_line(app_dir: &Path, shown: &str, d: &Diag) -> String {
    let (line, column) = match &d.span {
        Some(span) => {
            let column = std::fs::read_to_string(app_dir.join(&d.file))
                .ok()
                .and_then(|src| {
                    let before = src.get(..span.bytes.start)?;
                    Some(before.rsplit('\n').next().unwrap_or("").chars().count() + 1)
                });
            (Some(span.line), column)
        }
        None => (None, None),
    };
    serde_json::json!({
        "file": format!("{shown}/{}", d.file),
        "line": line,
        "column": column,
        "severity": match d.level {
            Level::Error => "error",
            Level::Warning => "warning",
        },
        "message": d.msg,
    })
    .to_string()
}

/// Prints diagnostics to stdout as JSON lines (see [`json_line`]).
pub fn render_json(app_dir: &Path, shown: &str, diags: &Diags) {
    for d in &diags.0 {
        println!("{}", json_line(app_dir, shown, d));
    }
}
