//! File-scoped diagnostics: `✗ products/$id/page.dart:4  message`.

use std::fmt;

#[derive(Debug, Clone, PartialEq)]
pub enum Level {
    Error,
    Warning,
}

#[derive(Debug, Clone)]
pub struct Diag {
    pub level: Level,
    pub file: String,
    pub line: usize,
    pub msg: String,
}

#[derive(Debug, Default)]
pub struct Diags(pub Vec<Diag>);

impl Diags {
    pub fn error(&mut self, file: &str, line: usize, msg: impl Into<String>) {
        self.0.push(Diag { level: Level::Error, file: file.into(), line, msg: msg.into() });
    }

    pub fn warn(&mut self, file: &str, line: usize, msg: impl Into<String>) {
        self.0.push(Diag { level: Level::Warning, file: file.into(), line, msg: msg.into() });
    }

    pub fn has_errors(&self) -> bool {
        self.0.iter().any(|d| d.level == Level::Error)
    }
}

impl fmt::Display for Diag {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mark = match self.level {
            Level::Error => "✗",
            Level::Warning => "!",
        };
        if self.line > 0 {
            write!(f, "{mark} {}:{}  {}", self.file, self.line, self.msg)
        } else {
            write!(f, "{mark} {}  {}", self.file, self.msg)
        }
    }
}
