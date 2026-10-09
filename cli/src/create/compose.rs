//! The shared files of a new app, composed from the fragments of the chosen features.
//!
//! Four files are never written by one feature: `pubspec.yaml`, `lib/app/startup.dart`,
//! `lib/app/app.dart` and `lib/main.dart`. Every feature hands this module a fragment (its
//! dependencies, its [`Startup`]) and this module is the only code that writes them, so two
//! features cannot disagree about a file, and the result is the same however they were asked for:
//!
//! - **imports** are sorted (`dart:` first, then `package:`, then the rest) and deduplicated;
//! - **startup steps** run by [`Phase`](super::recipes::Phase) (telemetry sinks first, as
//!   `docs/observability.md` has it, then the session, then the rest), and by the feature table's
//!   order inside a phase;
//! - **`zone()`** comes from at most one feature (a second is an error naming both);
//! - **`startup()`** is `async` when a step awaits, and the file is not written at all when no
//!   feature adds a step (the base app has none).
//!
//! It is pure: strings in, strings out, pinned by the goldens in `tests/golden/create/`.

use std::fmt::Write as _;

use anyhow::{Result, bail};
use serde::Serialize;

use super::plan::{BASE_FLOOR, REF, REPO_URL, floor_of};
use super::recipes::{Phase, Recipe, Source, Startup, StepKind, ThirdParty, companion_closure};
use crate::templates;

/// `text` as a YAML scalar: as it is when that reads back the same, else in single quotes.
fn scalar(text: &str) -> String {
    let plain = text
        .chars()
        .next()
        .is_some_and(|c| c.is_ascii_alphanumeric() || c == '/')
        && !text.ends_with(' ')
        && text
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || " ._,()/+-".contains(c));
    if plain {
        text.to_string()
    } else {
        format!("'{}'", text.replace('\'', "''"))
    }
}
/// One entry of `dependencies:` or `dependency_overrides:`, as the template writes it.
#[derive(Serialize)]
struct Dep {
    name: String,
    /// `name:` alone, or `name: "<range>"`.
    head: String,
    /// The lines nested under `name:`.
    lines: Vec<String>,
}

#[derive(Serialize)]
struct Override {
    name: String,
    path: String,
}

#[derive(Serialize)]
struct PubspecCx<'a> {
    name: &'a str,
    description: String,
    floor: String,
    deps: Vec<Dep>,
    dev_deps: Vec<Dep>,
    config: Vec<String>,
    assets: Vec<&'a str>,
    overrides: Vec<Override>,
}

/// The entries of `dependencies:` (or `dev_dependencies:`) for third-party packages.
fn third_party<'a>(packages: impl Iterator<Item = &'a ThirdParty>) -> Vec<Dep> {
    packages
        .map(|tp| {
            let (head, lines) = match tp.source {
                Source::Range(range) => (format!("{}: \"{range}\"", tp.name), vec![]),
                Source::Sdk(sdk) => (format!("{}:", tp.name), vec![format!("sdk: {sdk}")]),
                Source::Git { url, commit } => (
                    format!("{}:", tp.name),
                    vec![
                        "git:".to_string(),
                        format!("  url: {url}"),
                        format!("  ref: {commit}"),
                    ],
                ),
            };
            Dep {
                name: tp.name.to_string(),
                head,
                lines,
            }
        })
        .collect()
}

/// The pubspec of the app: a function of the name, the features and where the packages come from.
pub fn pubspec(
    name: &str,
    description: &str,
    features: &[&Recipe],
    local: Option<&str>,
) -> Result<String> {
    let mut companions: Vec<&str> = features
        .iter()
        .flat_map(|r| r.companions.iter().copied())
        .collect();
    companions.sort_unstable();
    companions.dedup();
    let package_dep = |package: &str| -> Dep {
        let lines = match local {
            Some(root) => vec![format!(
                "path: {}",
                scalar(&format!("{root}/packages/{package}"))
            )],
            None => vec![
                "git:".to_string(),
                format!("  url: {REPO_URL}"),
                format!("  path: packages/{package}"),
                format!("  ref: {REF}"),
            ],
        };
        Dep {
            name: package.to_string(),
            head: format!("{package}:"),
            lines,
        }
    };
    let mut deps = vec![package_dep("fespalier")];
    deps.extend(companions.iter().map(|c| package_dep(c)));
    deps.extend(third_party(
        features.iter().flat_map(|r| r.third_party.iter()),
    ));
    let mut dev_deps = third_party(features.iter().flat_map(|r| r.dev_third_party.iter()));
    dev_deps.sort_by(|a, b| a.name.cmp(&b.name));
    dev_deps.dedup_by(|a, b| a.name == b.name);
    deps.sort_by(|a, b| a.name.cmp(&b.name));
    deps.dedup_by(|a, b| a.name == b.name);
    if let Some(dep) = deps.iter().find(|d| d.name == name) {
        bail!(
            "the app cannot be named `{name}`: it depends on a package of that name ({})",
            dep.name
        );
    }
    let overrides = match local {
        Some(root) if !companions.is_empty() => {
            let mut all = companion_closure(&companions);
            all.push("fespalier".to_string());
            all.sort();
            all.into_iter()
                .map(|package| Override {
                    path: scalar(&format!("{root}/packages/{package}")),
                    name: package,
                })
                .collect()
        }
        _ => vec![],
    };
    // Two features may ask for the same key (`telemetry: true`); it is written once.
    let mut config: Vec<String> = vec![];
    for line in features.iter().flat_map(|r| r.config.iter().copied()) {
        if !config.iter().any(|c| c == line) {
            config.push(line.to_string());
        }
    }
    config.extend(smoke_skip_lines(features));
    let mut assets: Vec<&str> = features
        .iter()
        .flat_map(|r| r.startup.assets.iter().copied())
        .collect();
    assets.dedup();
    let floor = features
        .iter()
        .map(|r| r.flutter_floor)
        .chain([BASE_FLOOR])
        .max_by_key(|f| floor_of(f))
        .unwrap_or(BASE_FLOOR);
    Ok(templates::render(
        "create/pubspec.yaml",
        PubspecCx {
            name,
            description: scalar(description),
            floor: floor.to_string(),
            deps,
            dev_deps,
            config,
            assets,
            overrides,
        },
    ))
}

/// The `test:` section of the pubspec's `fespalier:` key that leaves out the routes the features
/// say `fsp test` cannot open on its own, each with the reason: none when no feature says so.
fn smoke_skip_lines(features: &[&Recipe]) -> Vec<String> {
    let skips: Vec<&(&str, &str)> = features
        .iter()
        .flat_map(|r| r.startup.smoke_skip.iter())
        .collect();
    if skips.is_empty() {
        return vec![];
    }
    let mut lines = vec!["test:".to_string()];
    lines.extend(
        skips
            .iter()
            .map(|(route, why)| format!("  # {route} {why}.")),
    );
    let routes: Vec<&str> = skips.iter().map(|(route, _)| *route).collect();
    lines.push(format!("  skip: [{}]", routes.join(", ")));
    lines
}

/// Which group of an import block a library is in: `dart:`, then `package:`, then the rest.
fn import_group(uri: &str) -> u8 {
    if uri.starts_with("dart:") {
        0
    } else if uri.starts_with("package:") {
        1
    } else {
        2
    }
}

/// An import block from `(uri, directive)` pairs: sorted by group and then by URI, one directive
/// per URI, and a blank line between the groups (`dart format` writes them that way, and a file
/// of ours must be what it leaves alone).
fn import_block(mut imports: Vec<(String, String)>) -> String {
    imports.sort_by(|a, b| (import_group(&a.0), &a.0).cmp(&(import_group(&b.0), &b.0)));
    imports.dedup_by(|a, b| a.0 == b.0);
    let mut out = String::new();
    let mut group = None;
    for (uri, directive) in &imports {
        let now = import_group(uri);
        if group.is_some_and(|g| g != now) {
            out.push('\n');
        }
        group = Some(now);
        out.push_str(directive);
        out.push('\n');
    }
    out
}

/// `import '<uri>';` for each URI.
fn plain_imports<'a>(uris: impl IntoIterator<Item = &'a str>) -> Vec<(String, String)> {
    uris.into_iter()
        .map(|entry| {
            // `package:a/a.dart show b`: the URI, then what follows it in the directive.
            let (uri, rest) = entry.split_once(' ').unwrap_or((entry, ""));
            let tail = if rest.is_empty() {
                String::new()
            } else {
                format!(" {rest}")
            };
            (uri.to_string(), format!("import '{uri}'{tail};"))
        })
        .collect()
}

/// `source` (a Dart file that starts with its imports) with `extra` libraries imported too: the
/// whole import block sorted and deduplicated. With nothing to add the file is returned as it is.
/// An import with a `show`, `hide` or `as` is kept whole and sorted by its URI.
#[must_use]
pub fn merge_imports(source: &str, extra: &[&str]) -> String {
    if extra.is_empty() {
        return source.to_string();
    }
    let mut lines = source.split_inclusive('\n').peekable();
    let mut imports: Vec<(String, String)> = vec![];
    while let Some(line) = lines.peek() {
        if !line.starts_with("import '") {
            break;
        }
        let uri = line.split('\'').nth(1).unwrap_or_default().to_string();
        imports.push((uri, line.trim_end().to_string()));
        lines.next();
    }
    // The ones the file has come first, so a `show` survives the deduplication.
    imports.extend(plain_imports(extra.iter().copied()));
    let mut out = import_block(imports);
    out.extend(lines);
    out
}

/// `lib/app/app.dart`: the starter, or the template of the one feature that has its own, with the
/// libraries the features import in it. `name` is the app's package name.
pub fn app_dart(name: &str, starter: &str, features: &[&Recipe]) -> Result<String> {
    let mut templates = features
        .iter()
        .filter_map(|r| r.startup.app_template.map(|t| (r.id, t)));
    let own = templates.next();
    if let Some((first, _)) = own
        && let Some((second, _)) = templates.next()
    {
        bail!("`{first}` and `{second}` both write lib/app/app.dart; an app has one");
    }
    let base = own.map_or_else(
        || starter.to_string(),
        |(_, template)| templates::render(template, serde_json::json!({ "package": name })),
    );
    let extra: Vec<&str> = features
        .iter()
        .flat_map(|r| r.startup.app_imports.iter().copied())
        .collect();
    Ok(merge_imports(&base, &extra))
}

/// `lib/main.dart`: the template with the libraries the features import in it.
#[must_use]
pub fn main_dart(template: &str, features: &[&Recipe]) -> String {
    let extra: Vec<&str> = features
        .iter()
        .flat_map(|r| r.startup.main_imports.iter().copied())
        .collect();
    merge_imports(template, &extra)
}

/// The lines of `decl` with a `const x = '<string>';` that is too long for 80 columns broken after
/// the `=`, as `dart format` does (a string cannot be broken, so the name of a long package moves
/// to its own line).
fn wrap_const(decl: &str) -> String {
    decl.lines()
        .map(|line| match line.split_once(" = ") {
            Some((head, value))
                if line.starts_with("const ") && value.starts_with('\'') && line.len() > 80 =>
            {
                format!("{head} =\n    {value}")
            }
            _ => line.to_string(),
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// A step as written: the composer makes some of its own (the sink install).
struct Written {
    kind: StepKind,
    phase: Phase,
    comment: String,
    code: String,
    awaits: bool,
}

/// `FespalierTelemetry.install(...)` for the sinks of the chosen features: one sink as it is,
/// several in one `combine`, formatted the way `dart format` leaves it (a line when it fits in 80
/// columns, the arguments one per line when it does not).
fn install_sinks(sinks: &[&str]) -> Option<String> {
    match sinks {
        [] => None,
        [sink] => {
            let line = format!("FespalierTelemetry.install({sink});");
            Some(if line.len() + 2 <= 80 {
                line
            } else {
                format!("FespalierTelemetry.install(\n  {sink},\n);")
            })
        }
        many => {
            let mut code =
                String::from("FespalierTelemetry.install(\n  FespalierTelemetry.combine([\n");
            for sink in many {
                let _ = writeln!(code, "    {sink},");
            }
            code.push_str("  ]),\n);");
            Some(code)
        }
    }
}

/// `lib/app/startup.dart`, or `None` when no feature adds anything to it. `name` is the app's
/// package name.
pub fn startup_dart(name: &str, features: &[&Recipe]) -> Result<Option<String>> {
    let startups = || features.iter().map(|r| (r.id, &r.startup));
    let one_of = |pick: fn(&Startup) -> Option<&'static str>| -> Result<Option<&'static str>> {
        let mut found = startups().filter_map(|(id, s)| pick(s).map(|z| (id, z)));
        let first = found.next();
        if let Some((first_id, _)) = first
            && let Some((second_id, _)) = found.next()
        {
            bail!("`{first_id}` and `{second_id}` both wrap main() in a zone(); an app has one");
        }
        Ok(first.map(|(_, z)| z))
    };
    // The zone of a feature wins; the weak one (otel_zone's, which Sentry's makes redundant) is
    // used only when no feature has one.
    let strong = one_of(|s| s.zone)?;
    let wrapper = one_of(|s| s.body_wrapper)?;
    let zone = match strong {
        Some(zone) => {
            // A feature whose SDK starts with the process has the zone call it before the body.
            let body = wrapper.map_or_else(|| "body".to_string(), |w| format!("() => {w}(body)"));
            if wrapper.is_some() && !zone.contains("{body}") {
                bail!(
                    "a feature starts something before main() runs, and the zone() of another cannot pass it the body"
                );
            }
            Some(zone.replace("{body}", &body))
        }
        None => one_of(|s| s.weak_zone)?.map(str::to_string),
    };
    let sinks: Vec<&str> = startups()
        .flat_map(|(_, s)| s.sinks.iter().copied())
        .collect();
    let mut steps: Vec<Written> = vec![];
    if let Some(code) = install_sinks(&sinks) {
        let comment = if sinks.len() > 1 {
            "One slot for every sink, before the router exists so the first navigation is reported."
        } else {
            "Before the router exists, so the first navigation is reported."
        };
        steps.push(Written {
            kind: StepKind::Statement,
            phase: Phase::Telemetry,
            comment: comment.to_string(),
            code,
            awaits: false,
        });
    }
    steps.extend(
        startups()
            .flat_map(|(_, s)| s.steps.iter())
            .map(|step| Written {
                kind: step.kind,
                phase: step.phase,
                comment: step.comment.to_string(),
                code: step.code.to_string(),
                awaits: step.awaits,
            }),
    );
    // Phase first, then the table's order (the sort is stable); the sink install is the first
    // of the telemetry phase.
    steps.sort_by_key(|s| s.phase);
    let decls: Vec<String> = startups()
        .flat_map(|(_, s)| s.decls.iter())
        .map(|d| wrap_const(&d.replace("{name}", name)))
        .collect();
    let provider_observers: Vec<&str> = startups()
        .flat_map(|(_, s)| s.provider_observers.iter().copied())
        .collect();
    let router_observers: Vec<&str> = startups()
        .flat_map(|(_, s)| s.router_observers.iter().copied())
        .collect();
    if steps.is_empty()
        && zone.is_none()
        && provider_observers.is_empty()
        && router_observers.is_empty()
    {
        return Ok(None);
    }
    let of_kind =
        |kind: StepKind| -> Vec<&Written> { steps.iter().filter(|s| s.kind == kind).collect() };
    let statements = of_kind(StepKind::Statement);
    let overrides = of_kind(StepKind::Override);
    let awaits = steps.iter().any(|s| s.awaits);
    let line = |out: &mut String, indent: &str, step: &Written| {
        if !step.comment.is_empty() {
            let _ = writeln!(out, "{indent}// {}", step.comment);
        }
        for code_line in step.code.lines() {
            let _ = writeln!(out, "{indent}{code_line}");
        }
    };

    let uris: Vec<String> = features
        .iter()
        .flat_map(|r| r.startup.imports.iter().copied())
        .chain(["package:fespalier/startup.dart"])
        .map(|uri| uri.replace("{name}", name))
        .collect();
    let mut out = import_block(plain_imports(uris.iter().map(String::as_str)));
    out.push('\n');
    for decl in &decls {
        out.push_str(decl);
        out.push_str("\n\n");
    }
    if let Some(zone) = &zone {
        out.push_str(zone);
        out.push_str("\n\n");
    }
    if !steps.is_empty() {
        let (ret, async_) = match (awaits, overrides.is_empty()) {
            (true, false) => ("Future<List<Override>>", " async"),
            (false, false) => ("List<Override>", ""),
            (true, true) => ("Future<void>", " async"),
            (false, true) => ("void", ""),
        };
        out.push_str(
            "/// Runs once before the app (docs/app-startup.md); the providers it returns are\n",
        );
        out.push_str(
            "/// overridden in the app's ProviderScope, so the first frame already has them.\n",
        );
        if statements.is_empty() {
            let _ = writeln!(out, "{ret} startup(){async_} => [");
            for step in &overrides {
                line(&mut out, "  ", step);
            }
            out.push_str("];\n");
        } else {
            let _ = writeln!(out, "{ret} startup(){async_} {{");
            for step in &statements {
                line(&mut out, "  ", step);
            }
            if !overrides.is_empty() {
                out.push_str("  return [\n");
                for step in &overrides {
                    line(&mut out, "    ", step);
                }
                out.push_str("  ];\n");
            }
            out.push_str("}\n");
        }
    }
    for (header, elements) in [
        (
            "List<ProviderObserver> get providerObservers",
            &provider_observers,
        ),
        (
            "List<NavigatorObserver> get routerObservers",
            &router_observers,
        ),
    ] {
        if elements.is_empty() {
            continue;
        }
        if !out.ends_with("\n\n") {
            out.push('\n');
        }
        // On one line when it fits in 80 columns, else one element per line: `dart format`
        // joins a list that fits, trailing comma or not.
        let joined: Vec<&str> = elements
            .iter()
            .map(|e| e.strip_suffix(',').unwrap_or(e))
            .collect();
        let one_line = format!("{header} => [{}];", joined.join(", "));
        if one_line.len() <= 80 {
            let _ = writeln!(out, "{one_line}");
        } else {
            let _ = writeln!(out, "{header} => [");
            for element in elements {
                let _ = writeln!(out, "  {element}");
            }
            out.push_str("];\n");
        }
    }
    Ok(Some(out))
}
