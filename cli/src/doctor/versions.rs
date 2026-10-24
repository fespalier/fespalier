//! The version rows of `fsp doctor` (since 0.23.0): fespalier and its companions against this
//! `fsp` and each other, `pubspec.lock`, `go_router`, Flutter and Dart.

use serde_yaml_ng::Value;

use super::{Facts, Row, Section, Status, leading_version};
use crate::pins::same_url;
use crate::upgrade::Version;

/// fespalier's own floor, the `environment:` of `packages/fespalier/pubspec.yaml`
/// (`doctor_tests::the_floors_are_the_packages_own` reads it).
pub const FLUTTER_FLOOR: Version = Version(3, 35, 0);
pub const DART_FLOOR: Version = Version(3, 9, 0);

/// The `go_router` versions fespalier supports: `>=17.2.3 <19.0.0` in its pubspec.
pub const GO_ROUTER: (Version, Version) = (Version(17, 2, 3), Version(19, 0, 0));

/// The companions that claim a newer Flutter than [`FLUTTER_FLOOR`], with the one they claim.
pub const NEWER_FLUTTER: [(&str, Version); 4] = [
    ("fespalier_download_background", Version(3, 47, 0)),
    ("fespalier_keypair", Version(3, 44, 0)),
    ("fespalier_keypair_dpop", Version(3, 44, 0)),
    ("fespalier_sign_keypair", Version(3, 44, 0)),
];

fn row(check: &'static str, status: Status, message: impl Into<String>) -> Row {
    Row::new(Section::Versions, check, status, message)
}

/// Where a dependency comes from, as the pubspec says it.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Source {
    Git {
        url: String,
        git_ref: Option<String>,
    },
    Path(String),
    /// Anything else: a version constraint, `hosted:`, `sdk:`.
    Other(String),
}

impl Source {
    fn of(v: &Value) -> Source {
        if let Some(git) = v.get("git") {
            return match git {
                Value::String(url) => Source::Git {
                    url: url.clone(),
                    git_ref: None,
                },
                _ => Source::Git {
                    url: git
                        .get("url")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    git_ref: git.get("ref").map(crate::config::shown_value),
                },
            };
        }
        if let Some(path) = v.get("path").and_then(Value::as_str) {
            return Source::Path(path.to_string());
        }
        Source::Other(match v {
            Value::Null => "any".into(),
            other => crate::config::shown_value(other),
        })
    }

    fn shown(&self) -> String {
        match self {
            Source::Git { url, git_ref } => match git_ref {
                Some(r) => format!("git {url}, ref {r}"),
                None => format!("git {url}, no ref"),
            },
            Source::Path(p) => format!("path {p}"),
            Source::Other(c) => format!("`{c}`"),
        }
    }
}

/// The packages of a section of the pubspec (`dependencies`), with their source, in order.
fn section(raw: Option<&Value>, name: &str) -> Vec<(String, Source)> {
    raw.and_then(|r| r.get(name))
        .and_then(Value::as_mapping)
        .map(|m| {
            m.iter()
                .filter_map(|(k, v)| Some((k.as_str()?.to_string(), Source::of(v))))
                .collect()
        })
        .unwrap_or_default()
}

/// The version `pubspec.lock` resolves `package` to.
fn locked(lock: &Value, package: &str) -> Option<String> {
    lock.get("packages")?
        .get(package)?
        .get("version")
        .map(crate::config::shown_value)
}

pub fn rows(facts: &Facts) -> Vec<Row> {
    let mut out = vec![];
    let raw = facts.raw.as_ref();
    let deps: Vec<(String, Source)> = section(raw, "dependencies")
        .into_iter()
        .chain(section(raw, "dev_dependencies"))
        .collect();
    let fespalier = deps.iter().find(|(n, _)| n == "fespalier").map(|(_, s)| s);
    let fsp = facts.fsp;
    out.push(match fespalier {
        None => row(
            "fespalier",
            Status::Error,
            "fespalier is not under `dependencies:`: the generated files import package:fespalier",
        ),
        Some(Source::Git {
            git_ref: Some(r), ..
        }) => match Version::parse(r) {
            Some(v) if v == fsp => row(
                "fespalier",
                Status::Ok,
                format!("fespalier: git, ref {r}, the version of this fsp"),
            ),
            Some(_) => row(
                "fespalier",
                Status::Error,
                crate::upgrade::ref_note(Some(r), fsp).unwrap_or_default(),
            ),
            None => row(
                "fespalier",
                Status::Info,
                format!(
                    "fespalier: git, ref {r}, which is not a release tag, so it is not compared with this fsp ({fsp})"
                ),
            ),
        },
        Some(Source::Git { git_ref: None, .. }) => row(
            "fespalier",
            Status::Warning,
            format!(
                "fespalier: git with no `ref:`, so the default branch: pin it to the release tag of this fsp, ref: {}",
                fsp.tag()
            ),
        ),
        Some(Source::Path(p)) => row(
            "fespalier",
            Status::Info,
            format!("fespalier: path {p}, not compared with this fsp ({fsp})"),
        ),
        Some(Source::Other(c)) => row(
            "fespalier",
            Status::Warning,
            format!(
                "fespalier: `{c}`, not a git dependency: fespalier is not published to pub.dev; depend on it by git at ref: {}",
                fsp.tag()
            ),
        ),
    });
    out.extend(companions(&deps, fespalier));
    for (name, source) in section(raw, "dependency_overrides") {
        if name == "fespalier" || name.starts_with("fespalier_") {
            out.push(
                row(
                    "override",
                    Status::Info,
                    format!(
                        "{name}: `dependency_overrides:` says {}, which wins over `dependencies:`",
                        source.shown()
                    ),
                )
                .about(name),
            );
        }
    }
    out.extend(lock_rows(facts, &deps));
    out.extend(toolchain_rows(facts, &deps));
    out
}

/// Every `fespalier_*` dependency against fespalier's own source.
fn companions(deps: &[(String, Source)], fespalier: Option<&Source>) -> Vec<Row> {
    let mut out = vec![];
    for (name, source) in deps.iter().filter(|(n, _)| n.starts_with("fespalier_")) {
        let r = match (fespalier, source) {
            (Some(Source::Git { url, git_ref }), Source::Git { url: u, git_ref: r }) => {
                if !same_url(url, u) {
                    row(
                        "companion",
                        Status::Warning,
                        format!(
                            "{name}: url {u}, and fespalier's is {url}: give every companion fespalier's url and ref"
                        ),
                    )
                } else if r != git_ref {
                    row(
                        "companion",
                        Status::Error,
                        format!(
                            "{name}: ref {}, and fespalier's is {}: give every companion fespalier's url and ref, or move them together with `fsp upgrade --app`",
                            r.as_deref().unwrap_or("none"),
                            git_ref.as_deref().unwrap_or("none")
                        ),
                    )
                } else {
                    row(
                        "companion",
                        Status::Ok,
                        format!(
                            "{name}: git, ref {}, as fespalier",
                            r.as_deref().unwrap_or("none")
                        ),
                    )
                }
            }
            (Some(Source::Git { .. }), Source::Other(c)) => row(
                "companion",
                Status::Warning,
                format!(
                    "{name}: `{c}`, not a git dependency: the companions are not published; give it fespalier's url and ref"
                ),
            ),
            (_, other) => row(
                "companion",
                Status::Info,
                format!("{name}: {}, not compared", other.shown()),
            ),
        };
        out.push(r.about(name.clone()));
    }
    out
}

/// What `pubspec.lock` resolved: fespalier and its companions against this fsp, and `go_router`.
fn lock_rows(facts: &Facts, deps: &[(String, Source)]) -> Vec<Row> {
    let Some(lock) = &facts.lock else {
        return vec![if facts.workspace_member {
            row(
                "lock",
                Status::Skipped,
                "no pubspec.lock at the root of the pub workspace (`resolution: workspace`: pub keeps the one lock there, none beside this pubspec): run `flutter pub get` in the workspace; the versions it resolves (fespalier's, go_router's) are not checked",
            )
        } else {
            row(
                "lock",
                Status::Skipped,
                "no pubspec.lock: run `flutter pub get`; the versions it resolves (fespalier's, go_router's) are not checked",
            )
        }];
    };
    let mut out = vec![];
    let fsp = facts.fsp;
    let fespalier = locked(lock, "fespalier");
    match fespalier.as_deref().map(|v| (v, Version::parse(v))) {
        Some((v, Some(parsed))) if parsed == fsp => out.push(row(
            "lock",
            Status::Ok,
            format!("pubspec.lock resolves fespalier {v}, the version of this fsp"),
        )),
        // A lock ahead of this fsp is not fixed by moving the refs back.
        Some((v, Some(parsed))) if parsed > fsp => out.push(row(
            "lock",
            Status::Warning,
            format!(
                "pubspec.lock resolves fespalier {v}, and this fsp writes code for {fsp}: upgrade fsp (`fsp upgrade`), or run `dart run fespalier` to use the fsp of the pin"
            ),
        )),
        Some((v, _)) => out.push(row(
            "lock",
            Status::Warning,
            format!(
                "pubspec.lock resolves fespalier {v}, and this fsp writes code for {fsp}: move the refs to {} with `fsp upgrade --app`, or run `dart run fespalier` to use the fsp of the pin",
                fsp.tag()
            ),
        )),
        None => out.push(row(
            "lock",
            Status::Warning,
            "pubspec.lock has no fespalier: run `flutter pub get`",
        )),
    }
    if let Some(fv) = &fespalier {
        for (name, _) in deps.iter().filter(|(n, _)| n.starts_with("fespalier_")) {
            if let Some(v) = locked(lock, name)
                && &v != fv
            {
                out.push(
                    row(
                        "lock",
                        Status::Warning,
                        format!(
                            "pubspec.lock resolves {name} {v}, and fespalier {fv}: give every companion fespalier's ref, then run `flutter pub get`"
                        ),
                    )
                    .about(name.clone()),
                );
            }
        }
    }
    let (low, high) = GO_ROUTER;
    let range = format!(">={low} <{high}");
    out.push(match locked(lock, "go_router") {
        None => row(
            "go_router",
            Status::Skipped,
            "pubspec.lock has no go_router: run `flutter pub get`",
        ),
        Some(v) => match leading_version(&v) {
            Some(parsed) if parsed >= low && parsed < high => row(
                "go_router",
                Status::Ok,
                format!("go_router {v} (pubspec.lock), in what fespalier supports, {range}"),
            ),
            _ => row(
                "go_router",
                Status::Error,
                format!(
                    "go_router {v} (pubspec.lock) is outside what fespalier supports, {range}: a `dependency_overrides:` entry or a stale lock; remove the override and run `flutter pub get`"
                ),
            ),
        },
    });
    out
}

/// Flutter and Dart against fespalier's floor, and the companions that need a newer Flutter.
fn toolchain_rows(facts: &Facts, deps: &[(String, Source)]) -> Vec<Row> {
    let t = match &facts.toolchain {
        Ok(t) => t,
        Err(why) => {
            return vec![row(
                "flutter",
                Status::Skipped,
                format!("{why}: Flutter and Dart are not checked"),
            )];
        }
    };
    // A clone without tags reports 0.0.0 (`0.0.0-unknown`): every comparison would fail alike.
    let unknown = t.flutter == Version(0, 0, 0);
    let shown = if t.flutter_pre {
        format!("{} (a pre-release)", t.flutter)
    } else {
        t.flutter.to_string()
    };
    // Pub orders `3.35.0-0.1.pre` below `3.35.0`.
    let meets = |floor: Version| t.flutter > floor || (t.flutter == floor && !t.flutter_pre);
    let mut out = vec![if unknown {
        row(
            "flutter",
            Status::Error,
            format!(
                "Flutter does not know its own version (it reports {}): the checkout has no release tags, so pub cannot compare it with fespalier's floor, {FLUTTER_FLOOR}; run `git fetch --tags` in the Flutter folder, or install a release",
                t.flutter
            ),
        )
    } else if meets(FLUTTER_FLOOR) {
        row(
            "flutter",
            Status::Ok,
            format!("Flutter {shown}, at or above fespalier's floor, {FLUTTER_FLOOR}"),
        )
    } else {
        row(
            "flutter",
            Status::Error,
            format!("Flutter {shown} is below fespalier's floor, {FLUTTER_FLOOR}: upgrade Flutter"),
        )
    }];
    for (name, floor) in NEWER_FLUTTER {
        if !unknown && !meets(floor) && deps.iter().any(|(n, _)| n == name) {
            out.push(
                row(
                    "flutter",
                    Status::Error,
                    format!("{name} needs Flutter {floor}, and this is {shown}"),
                )
                .about(name),
            );
        }
    }
    out.push(if t.dart >= DART_FLOOR {
        row(
            "dart",
            Status::Ok,
            format!(
                "Dart {}, at or above fespalier's floor, {DART_FLOOR}",
                t.dart
            ),
        )
    } else {
        row(
            "dart",
            Status::Error,
            format!(
                "Dart {} is below fespalier's floor, {DART_FLOOR}: upgrade Flutter",
                t.dart
            ),
        )
    });
    out
}
