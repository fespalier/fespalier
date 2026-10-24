//! The check rows of `fsp doctor` (since 0.23.0): what `fsp gen` never checks, the `build_runner`
//! trap, `lib/main.dart`, and `fsp check` in one line.

use super::{Facts, Row, Section, Status};
use crate::config::{Config, MainMode};

fn row(check: &'static str, status: Status, message: impl Into<String>) -> Row {
    Row::new(Section::Checks, check, status, message)
}

pub fn rows(facts: &Facts) -> Vec<Row> {
    let cfg = match &facts.pubspec {
        Ok(p) => &p.config,
        Err(why) => return vec![row("config", Status::Error, why.clone())],
    };
    let mut out = sections(cfg);
    if let Some(app) = &facts.app {
        for (file, message) in &app.build_runner {
            out.push(row("build_runner", Status::Warning, message.clone()).about(file.clone()));
        }
        if cfg.build_runner && app.build_runner.is_empty() {
            out.push(row(
                "build_runner",
                Status::Ok,
                "build_runner is a dependency, and no file fsp writes has an X.dart beside it for its builders to claim",
            ));
        }
        out.extend(main_dart(facts, cfg, app.main.0));
        let c = &app.check;
        // What `fsp check` prints that a row above already is (`forms`, `build_runner`).
        let besides = if c.listed > 0 {
            " besides what the rows above report"
        } else {
            ""
        };
        out.push(match (&c.failure, c.errors, c.warnings) {
            (Some(why), _, _) => row("fsp_check", Status::Error, why.clone()),
            (None, 0, 0) if c.listed > 0 => row(
                "fsp_check",
                Status::Info,
                "`fsp check` finds nothing besides what the rows above report: run `fsp check` to see it",
            ),
            (None, 0, 0) => row(
                "fsp_check",
                Status::Ok,
                format!(
                    "`fsp check`: {}, no errors",
                    crate::plural(c.routes, "route")
                ),
            ),
            (None, 0, w) => row(
                "fsp_check",
                Status::Warning,
                format!(
                    "`fsp check`: {}, and {}{besides}: run `fsp check` to see them",
                    crate::plural(c.routes, "route"),
                    crate::plural(w, "warning")
                ),
            ),
            (None, e, w) => row(
                "fsp_check",
                Status::Error,
                format!(
                    "`fsp check` finds {} and {}{besides}: run `fsp check` to see them",
                    crate::plural(e, "error"),
                    crate::plural(w, "warning")
                ),
            ),
        });
    }
    out
}

/// The sections only their own command checks, checked as that command would.
fn sections(cfg: &Config) -> Vec<Row> {
    let mut out = vec![];
    let mut add = |key: &str, command: &str, result: anyhow::Result<()>| {
        out.push(
            match result {
                Ok(()) => row(
                    "section",
                    Status::Ok,
                    format!("`{key}:` is what `{command}` needs (only that command reads it)"),
                ),
                Err(e) => row("section", Status::Error, format!("{e:#}")),
            }
            .about(key.to_string()),
        );
    };
    if let Some(links) = &cfg.links {
        add("links", "fsp links", links.validate().map(|_| ()));
    }
    if let Some(maestro) = &cfg.maestro {
        add(
            "maestro",
            "fsp maestro",
            maestro.validate(cfg.links.as_ref()).map(|_| ()),
        );
    }
    if let Some(size) = &cfg.size {
        add("size", "fsp size", size.validate().map(|_| ()));
    }
    if let Some(test) = &cfg.test {
        add("test", "fsp test", test.validate().map(|_| ()));
    }
    out
}

/// Whether the app's own code runs what fsp generated: `AppMain.run()`, or `AppAdapters` with
/// `main: manual`. Found by text, in the Dart files under `lib/` without their comments: the
/// `main()` in `lib/main.dart` may hand over to another file (`bootstrap.dart`, a flavour's
/// `main_dev.dart`).
fn main_dart(facts: &Facts, cfg: &Config, written: bool) -> Vec<Row> {
    if written {
        let runs = facts.files_with("AppMain.run(");
        let has_main = facts.sources.iter().any(|(f, _)| f == "lib/main.dart");
        return vec![if runs.contains(&"lib/main.dart") {
            row("main_dart", Status::Ok, "lib/main.dart calls AppMain.run()")
        } else if !runs.is_empty() {
            row(
                "main_dart",
                Status::Ok,
                format!(
                    "{} calls AppMain.run(); the entry point you run must reach it",
                    runs.join(", ")
                ),
            )
        } else if has_main {
            row(
                "main_dart",
                Status::Warning,
                format!(
                    "no Dart file under lib/ calls AppMain.run(), so the generated main() ({}) does not run, nor the adapters, startup.dart and `otel: true` with it: in lib/main.dart, `Future<void> main() => AppMain.run();`",
                    cfg.output_main()
                ),
            )
        } else {
            row(
                "main_dart",
                Status::Info,
                "no lib/main.dart, and no Dart file under lib/ calls AppMain.run(): the entry point you run must call AppMain.run()",
            )
        }];
    }
    if cfg.main == MainMode::Manual && !cfg.adapters.is_empty() {
        let files = facts.files_with("AppAdapters.");
        return vec![if files.is_empty() {
            row(
                "main_dart",
                Status::Warning,
                "`main: manual` with adapters, and no Dart file under lib/ calls AppAdapters: the adapters do not run (docs/adapters.md, \"With main: manual: AppAdapters\")",
            )
        } else {
            row(
                "main_dart",
                Status::Ok,
                format!("`main: manual`, and {} calls AppAdapters", files.join(", ")),
            )
        }];
    }
    vec![]
}
