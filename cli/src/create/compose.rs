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
use super::recipes::{Recipe, Source, Step, StepKind, companion_closure};
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
    config: Vec<&'a str>,
    overrides: Vec<Override>,
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
    for tp in features.iter().flat_map(|r| r.third_party.iter()) {
        let (head, lines) = match tp.source {
            Source::Range(range) => (format!("{}: \"{range}\"", tp.name), vec![]),
            Source::Git { url, commit } => (
                format!("{}:", tp.name),
                vec![
                    "git:".to_string(),
                    format!("  url: {url}"),
                    format!("  ref: {commit}"),
                ],
            ),
        };
        deps.push(Dep {
            name: tp.name.to_string(),
            head,
            lines,
        });
    }
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
            config: features
                .iter()
                .flat_map(|r| r.config.iter().copied())
                .collect(),
            overrides,
        },
    ))
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
        .map(|uri| (uri.to_string(), format!("import '{uri}';")))
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

/// `lib/app/app.dart`: the starter with the libraries the features import in it.
#[must_use]
pub fn app_dart(starter: &str, features: &[&Recipe]) -> String {
    let extra: Vec<&str> = features
        .iter()
        .flat_map(|r| r.startup.app_imports.iter().copied())
        .collect();
    merge_imports(starter, &extra)
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

/// `lib/app/startup.dart`, or `None` when no feature adds anything to it.
pub fn startup_dart(features: &[&Recipe]) -> Result<Option<String>> {
    let mut zones = features.iter().filter(|r| r.startup.zone.is_some());
    let zone = zones.next();
    if let Some(first) = zone
        && let Some(second) = zones.next()
    {
        bail!(
            "`{}` and `{}` both wrap main() in a zone(); an app has one",
            first.id,
            second.id
        );
    }
    // Phase first, then the table's order (the sort is stable).
    let mut steps: Vec<&Step> = features
        .iter()
        .flat_map(|r| r.startup.steps.iter())
        .collect();
    steps.sort_by_key(|s| s.phase);
    if steps.is_empty() && zone.is_none() {
        return Ok(None);
    }
    let of_kind = |kind: StepKind| -> Vec<&Step> {
        steps.iter().copied().filter(|s| s.kind == kind).collect()
    };
    let statements = of_kind(StepKind::Statement);
    let overrides = of_kind(StepKind::Override);
    let awaits = steps.iter().any(|s| s.awaits);
    let line = |out: &mut String, indent: &str, step: &Step| {
        if !step.comment.is_empty() {
            let _ = writeln!(out, "{indent}// {}", step.comment);
        }
        let _ = writeln!(out, "{indent}{}", step.code);
    };

    let mut out = import_block(plain_imports(
        features
            .iter()
            .flat_map(|r| r.startup.imports.iter().copied())
            .chain(["package:fespalier/startup.dart"]),
    ));
    out.push('\n');
    if let Some(zone) = zone.and_then(|r| r.startup.zone) {
        out.push_str(zone);
        out.push_str("\n\n");
    }
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
    Ok(Some(out))
}
