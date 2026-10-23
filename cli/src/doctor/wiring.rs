//! The wiring rows of `fsp doctor` (since 0.23.0): what the generated `main()` does, and why.

use serde_yaml_ng::Value;

use super::{Facts, Row, Section, Status};
use crate::adapters;
use crate::config::{Config, MainMode};
use crate::tasks::Tasks;

fn row(check: &'static str, status: Status, message: impl Into<String>) -> Row {
    Row::new(Section::Wiring, check, status, message)
}

pub fn rows(facts: &Facts) -> Vec<Row> {
    let (Some(cfg), Some(app)) = (facts.config(), facts.app.as_ref()) else {
        return vec![];
    };
    let mut out = vec![];
    let main_file = cfg.output_main();
    let (written, why) = &app.main;
    out.push(match (cfg.main, *written) {
        (MainMode::Manual, _) => row(
            "main",
            Status::Info,
            format!(
                "no {main_file}: `main: manual`, so your own main() runs the app, and the root files of {} are not read",
                cfg.app_dir
            ),
        ),
        (_, true) => row(
            "main",
            Status::Ok,
            format!("{main_file} is written: {}", why.join(", ")),
        ),
        (_, false) => row(
            "main",
            Status::Info,
            format!(
                "no {main_file}: `main: auto` finds no app.dart, startup.dart or splash.dart in {}, no adapter and no `otel: true`, so lib/main.dart runs the router itself",
                cfg.app_dir
            ),
        ),
    });
    if *written {
        out.extend(root_files(cfg, &app.root));
        out.push(if app.swaps {
            row(
                "hot_reload",
                Status::Ok,
                "a hot reload in `fsp dev` swaps the route table",
            )
        } else {
            row(
                "hot_reload",
                Status::Info,
                "a hot reload cannot swap the route table, because app.dart's router() builds the router another way: `fsp dev` restarts when the routes change",
            )
        });
    }
    out.extend(adapter_rows(facts, cfg));
    out.push(if cfg.telemetry {
        row(
            "telemetry",
            Status::Info,
            "on: navigations, guards, data, actions and deferred loads report to FespalierTelemetry",
        )
    } else {
        row(
            "telemetry",
            Status::Info,
            "off: nothing is reported (`telemetry: true` turns it on)",
        )
    });
    out.push(if cfg.otel {
        row(
            "otel",
            Status::Info,
            "on: the generated main() starts otel_zone and installs FespalierOtel",
        )
    } else {
        row(
            "otel",
            Status::Info,
            "off: the generated main() starts no OpenTelemetry SDK",
        )
    });
    out.push(match (app.forms, cfg.forms_dependency) {
        (0, _) => row("forms", Status::Info, "no action has a form()"),
        (n, true) => row(
            "forms",
            Status::Ok,
            format!(
                "{}, and fespalier_forms is a dependency",
                actions_with_form(n)
            ),
        ),
        (n, false) => row(
            "forms",
            Status::Error,
            format!(
                "{}, and fespalier_forms is not under `dependencies:`: the generated file imports it (`fsp check` reports each form())",
                actions_with_form(n)
            ),
        ),
    });
    out.push(match app.deferred {
        0 => row("deferred", Status::Info, "no page loads its code on demand"),
        1 => row(
            "deferred",
            Status::Info,
            "1 page loads its code on demand (a chunk of its own on the web)",
        ),
        n => row(
            "deferred",
            Status::Info,
            format!("{n} pages load their code on demand (a chunk each on the web)"),
        ),
    });
    out.push(match Tasks::from_config(cfg) {
        Ok(tasks) => row(
            "tasks",
            Status::Ok,
            format!(
                "{}: `fsp run` lists them (dev and build have a default)",
                tasks.names().join(", ")
            ),
        ),
        Err(e) => row("tasks", Status::Error, format!("{e:#}")),
    });
    out
}

/// `1 action with a form()`, `2 actions with a form()` (`plural` would say `form()s`).
fn actions_with_form(n: usize) -> String {
    if n == 1 {
        "1 action with a form()".into()
    } else {
        format!("{n} actions with a form()")
    }
}

/// One row per root file: what it gives the generated `main()`.
fn root_files(cfg: &Config, root: &crate::entry::RootReport) -> Vec<Row> {
    root.files
        .iter()
        .map(|file| {
            let path = format!("{}/{file}", cfg.app_dir);
            let message = match file.rsplit('/').next().unwrap_or(file) {
                "app.dart" if root.own_router => {
                    format!(
                        "{path} builds the widget around the router, and the router (its router())"
                    )
                }
                "app.dart" => format!("{path} builds the widget around the router"),
                "startup.dart" if root.startup.is_empty() => format!(
                    "{path} gives the generated main() nothing it can call: `fsp check` says why"
                ),
                "startup.dart" => {
                    let names: Vec<String> = root
                        .startup
                        .iter()
                        .map(|n| {
                            if *n == "startup()" && root.startup_overrides {
                                "startup() (which returns overrides)".to_string()
                            } else {
                                (*n).to_string()
                            }
                        })
                        .collect();
                    format!("{path} gives the generated main() {}", names.join(", "))
                }
                _ => format!(
                    "{path} is shown while startup() or ready() runs, and when either fails"
                ),
            };
            row("root_file", Status::Info, message).about(path)
        })
        .collect()
}

/// The names under `dependencies:`, in order.
fn dependencies(raw: Option<&Value>) -> Vec<String> {
    raw.and_then(|r| r.get("dependencies"))
        .and_then(Value::as_mapping)
        .map(|m| {
            m.keys()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

/// A row per adapter that is on, and per first-party adapter package that is a dependency and off.
fn adapter_rows(facts: &Facts, cfg: &Config) -> Vec<Row> {
    let mut out = vec![];
    let how = if cfg.adapters_auto {
        "found by `adapters: auto` under `dependencies:`"
    } else {
        "listed in `adapters:`"
    };
    for name in &cfg.adapters {
        let r = match adapters::first_party(name) {
            Some(a) => {
                let call = format!("{}.configure(", a.configure);
                let files = facts.files_with(&call);
                if files.is_empty() {
                    row(
                        "adapter",
                        Status::Warning,
                        format!(
                            "{name}: on, {how}, and no Dart file under lib/ calls `{call}...)`: unconfigured, the adapter reports an error once and does nothing; call it in main() before AppMain.run() (docs/adapters.md, \"Adapters that need your code\")"
                        ),
                    )
                } else {
                    row(
                        "adapter",
                        Status::Ok,
                        format!("{name}: on, {how}; {} calls `{call}...)`", files.join(", ")),
                    )
                }
            }
            None => row(
                "adapter",
                Status::Info,
                format!(
                    "{name}: on, {how}; fsp does not read package:{name}/fespalier_adapter.dart"
                ),
            ),
        };
        out.push(r.about(name.clone()));
    }
    for name in dependencies(facts.raw.as_ref()) {
        if adapters::is_first_party(&name) && !cfg.adapters.contains(&name) {
            out.push(
                row(
                    "adapter",
                    Status::Info,
                    format!(
                        "{name}: off: a dependency that ships an adapter, and `adapters:` does not list it (list it, or write `adapters: auto`, to wire it)"
                    ),
                )
                .about(name),
            );
        }
    }
    out
}
