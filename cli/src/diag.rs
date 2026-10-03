//! File-scoped diagnostics. `Display` gives the one-line form used in tests
//! (`✗ products/$id/page.dart:4  message`); [`render`] prints them with source
//! snippets through codespan-reporting.

use std::fmt;
use std::io::IsTerminal;
use std::path::{Path, PathBuf};

use codespan_reporting::diagnostic::{Diagnostic, Label};
use codespan_reporting::files::SimpleFiles;
use codespan_reporting::term::{
    self,
    termcolor::{ColorChoice, NoColor, StandardStream, WriteColor},
};

use crate::dart::Span;

#[derive(Debug, Clone, PartialEq)]
pub enum Level {
    Error,
    Warning,
}

/// What [`Diag::file`] is relative to.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Base {
    /// The app folder (`lib/app` by default): what the tree's own diagnostics are about.
    #[default]
    App,
    /// The project root: a lint over a file anywhere in `lib/` (`lib/screens/home.dart`).
    Project,
}

#[derive(Debug, Clone)]
pub struct Diag {
    pub level: Level,
    pub base: Base,
    /// Relative to [`Diag::base`]: the app folder (`lib/app` by default) or the project.
    pub file: String,
    pub span: Option<Span>,
    pub msg: String,
}

#[derive(Debug, Clone, Default)]
pub struct Diags(pub Vec<Diag>);

impl Diags {
    pub fn error(&mut self, file: &str, span: Option<&Span>, msg: impl Into<String>) {
        self.add(Level::Error, Base::App, file, span, msg);
    }

    pub fn warn(&mut self, file: &str, span: Option<&Span>, msg: impl Into<String>) {
        self.add(Level::Warning, Base::App, file, span, msg);
    }

    /// `file` relative to `base`; [`error`](Diags::error) and [`warn`](Diags::warn) are this
    /// with [`Base::App`].
    pub fn add(
        &mut self,
        level: Level,
        base: Base,
        file: &str,
        span: Option<&Span>,
        msg: impl Into<String>,
    ) {
        let d = Diag {
            level,
            base,
            file: file.into(),
            span: span.cloned(),
            msg: msg.into(),
        };
        // Inherited files can trip the same check from several routes.
        if !self
            .0
            .iter()
            .any(|x| x.base == d.base && x.file == d.file && x.msg == d.msg && x.span == d.span)
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

/// The project root, given the app folder `app_dir` and how the user spells it (`lib/app`).
fn project_of<'a>(app_dir: &'a Path, shown: &str) -> Option<&'a Path> {
    app_dir.ancestors().nth(shown.split('/').count())
}

/// Where `d`'s file is on disk.
fn source_path(app_dir: &Path, shown: &str, d: &Diag) -> Option<PathBuf> {
    match d.base {
        Base::App => Some(app_dir.join(&d.file)),
        Base::Project => project_of(app_dir, shown).map(|p| p.join(&d.file)),
    }
}

/// `d`'s file as it is shown: relative to the project root, `lib/app/page.dart`.
fn shown_file(shown: &str, d: &Diag) -> String {
    match d.base {
        Base::App => format!("{shown}/{}", d.file),
        Base::Project => d.file.clone(),
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
    emit_each(&mut out.lock(), app_dir, shown, diags, |d| eprintln!("{d}"));
}

/// The same rendering as [`render`], without colour, as lines: what `fsp dev` shows in its
/// `fsp` pane (since 0.9.0).
#[must_use]
pub fn render_plain(app_dir: &Path, shown: &str, diags: &Diags) -> Vec<String> {
    let mut lines = vec![];
    for d in &diags.0 {
        let mut buf = NoColor::new(Vec::new());
        let mut failed = false;
        emit_each(&mut buf, app_dir, shown, &Diags(vec![d.clone()]), |_| {
            failed = true;
        });
        if failed {
            lines.push(d.to_string());
        } else {
            lines.extend(
                String::from_utf8_lossy(&buf.into_inner())
                    .lines()
                    .map(str::to_string),
            );
        }
    }
    lines
}

/// Writes each diagnostic with its source to `out`; `fallback` gets one that cannot be written.
fn emit_each(
    out: &mut dyn WriteColor,
    app_dir: &Path,
    shown: &str,
    diags: &Diags,
    mut fallback: impl FnMut(&Diag),
) {
    let config = term::Config::default();
    let mut files = SimpleFiles::new();
    for d in &diags.0 {
        let base = match d.level {
            Level::Error => Diagnostic::error(),
            Level::Warning => Diagnostic::warning(),
        };
        let source = d
            .span
            .as_ref()
            .and_then(|_| std::fs::read_to_string(source_path(app_dir, shown, d)?).ok());
        let shown = shown_file(shown, d);
        let diagnostic = match (&d.span, source) {
            (Some(span), Some(src)) => {
                let id = files.add(shown, src);
                base.with_message(&d.msg)
                    .with_labels(vec![Label::primary(id, span.bytes.clone())])
            }
            _ => base.with_message(format!("{shown}: {}", d.msg)),
        };
        if term::emit_to_write_style(out, &config, &files, &diagnostic).is_err() {
            fallback(d);
        }
    }
}

/// Where a diagnostic is: its file (relative to the project root, as [`json_line`] spells it, and
/// on disk) and a 1-based line and column.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Loc {
    /// Relative to the project root: `lib/app/products/$id/page.dart`.
    pub file: String,
    /// Where `file` is on disk.
    pub path: PathBuf,
    pub line: usize,
    /// Counts characters.
    pub column: usize,
}

impl Loc {
    /// `lib/app/products/$id/page.dart:6:18`: how an editor's link detector reads it.
    #[must_use]
    pub fn text(&self) -> String {
        format!("{}:{}:{}", self.file, self.line, self.column)
    }
}

/// The place `d` points at, when it has a span and the file can be read.
#[must_use]
pub fn location(app_dir: &Path, shown: &str, d: &Diag) -> Option<Loc> {
    let span = d.span.as_ref()?;
    let path = source_path(app_dir, shown, d)?;
    let src = std::fs::read_to_string(&path).ok()?;
    let before = src.get(..span.bytes.start)?;
    Some(Loc {
        file: shown_file(shown, d),
        path,
        line: span.line,
        column: before.rsplit('\n').next().unwrap_or("").chars().count() + 1,
    })
}

/// One diagnostic as a JSON object, for editors:
/// `{"file","line","column","severity","message"}`. `file` is relative to the
/// project root (`lib/app/products/$id/page.dart`); `line` and `column` are
/// 1-based (the column counts characters) and `null` when the diagnostic isn't
/// about a place in the file.
pub fn json_line(app_dir: &Path, shown: &str, d: &Diag) -> String {
    let (line, column) = match &d.span {
        Some(span) => (
            Some(span.line),
            location(app_dir, shown, d).map(|l| l.column),
        ),
        None => (None, None),
    };
    serde_json::json!({
        "file": shown_file(shown, d),
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
