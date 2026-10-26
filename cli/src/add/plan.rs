//! What `fsp add` will do, decided without touching the disk or a process: the app's pubspec and
//! files in, a [`Plan`] out, pinned by `add_tests.rs`.
//!
//! A feature is the recipe `fsp create` has (`create/recipes.rs`, the one table), and every file is
//! what `fsp create` would write for the features the app ends up with: the feature's own files,
//! and the four files every feature shares (`lib/app/startup.dart`, `lib/app/app.dart`,
//! `lib/main.dart`, `test/routes/setup.dart`), composed by `create/compose.rs`. To know what is
//! the app's and what is fsp's, the plan works out which features the app has ([`present`]) and
//! composes each shared file twice, for those and for those plus the new ones. A file that is,
//! byte for byte, what `fsp create` writes for the features it has is rewritten; a file that is
//! not (the app changed it, or made it) is left alone, and the change is printed for a person to
//! make. A feature's own file that is there already is never written over.

use std::collections::BTreeMap;
use std::fmt::Write as _;

use anyhow::{Context, Result, anyhow, bail};
use serde_yaml_ng::Value;

use crate::config::{DEFAULT_APP_DIR, DEFAULT_OUTPUT, MainMode, Pubspec};
use crate::create::compose;
use crate::create::plan::{ALL, BASE_DART, FlutterVersion, resolve_features};
use crate::create::recipes::{Recipe, Source, ThirdParty, companion_closure};
use crate::pins::{self, Origin};
use crate::pubspec_edit::{self, Body, Edit, Place};
use crate::upgrade::Version;
use crate::{init, templates};

/// The files every feature adds to instead of writing: what `fsp create` composes.
pub const SHARED: [&str; 4] = [
    "lib/app/startup.dart",
    "lib/app/app.dart",
    "lib/main.dart",
    "test/routes/setup.dart",
];

/// Every file the plan reads: the shared ones, and every file of every feature (to tell which
/// features the app has).
#[must_use]
pub fn paths(table: &[Recipe]) -> Vec<String> {
    let mut out: Vec<String> = SHARED.iter().map(|p| (*p).to_string()).collect();
    out.extend(
        table
            .iter()
            .flat_map(|r| r.files.iter().map(|(_, path)| (*path).to_string())),
    );
    out.sort();
    out.dedup();
    out
}

/// What the plan is given: the app as it is.
pub struct Request<'a> {
    /// The features, as typed.
    pub features: &'a [String],
    /// The text of `pubspec.yaml`.
    pub pubspec: &'a str,
    /// The files of [`paths`] that are there, with their text.
    pub files: &'a BTreeMap<String, String>,
    /// The text of `pubspec_overrides.yaml`, when the app has one.
    pub overrides: Option<&'a str>,
    /// The packages the root of the app's pub workspace overrides, when the app says `resolution:
    /// workspace`: pub reads them with the app's own.
    pub workspace_overrides: &'a [String],
}

pub use crate::upgrade_app::OVERRIDES;

/// `pubspec_overrides.yaml` as it is and as the plan writes it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Overrides {
    pub before: String,
    pub after: String,
    /// What changes in it, a line each.
    pub changes: Vec<String>,
}

/// How a file is written.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Write {
    /// It is not there.
    New,
    /// It is what `fsp create` writes for the features the app had, so it is replaced.
    Update,
}

impl Write {
    #[must_use]
    pub fn word(self) -> &'static str {
        match self {
            Write::New => "new",
            Write::Update => "update",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct File {
    /// Relative to the app, `/`-separated.
    pub path: String,
    pub content: String,
    pub write: Write,
}

/// A change to a file the plan does not write, for a person to make.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ByHand {
    pub path: String,
    pub why: &'static str,
    /// The change, as lines: `+ ` added, `- ` removed, `  ` around them.
    pub change: String,
}

/// Everything `fsp add` does, in the order it does it.
#[derive(Debug, Clone)]
pub struct Plan {
    /// The Dart package name.
    pub package: String,
    /// The features added, in the table's order, requirements included.
    pub features: Vec<&'static str>,
    /// The features the app has, as read.
    pub present: Vec<&'static str>,
    pub notes: Vec<String>,
    /// The new `pubspec.yaml`, when it changes.
    pub pubspec: Option<String>,
    /// What changes in it, a line each.
    pub changes: Vec<String>,
    /// The new overrides of a checkout, when the app keeps its overrides in
    /// `pubspec_overrides.yaml` (since 0.23.1).
    pub overrides: Option<Overrides>,
    pub files: Vec<File>,
    pub by_hand: Vec<ByHand>,
    /// The Android `minSdk` the new features' plugins need.
    pub android_min_sdk: Option<u32>,
}

impl Plan {
    /// Nothing to write: every feature asked for is in the app.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.features.is_empty()
    }
}

/// The first release that has `fsp add`: the fsp of an older pin cannot be asked to run it.
const ADD_SINCE: Version = Version(0, 23, 0);

/// The refusal when the app pins another release of fespalier than the `fsp` that runs.
pub fn another_release(pin: Version, own: Version, features: &[String]) -> String {
    let (pin_tag, own_tag) = (pin.tag(), own.tag());
    let launcher = format!("`dart run fespalier add {}`", features.join(" "));
    if pin > own {
        format!(
            "this app pins fespalier {pin_tag}, and fsp {own} is older and writes the files and pins of {own_tag}; nothing was written. Upgrade fsp (`fsp upgrade`), or use the fsp of the pin: {launcher}"
        )
    } else if pin >= ADD_SINCE {
        format!(
            "this app pins fespalier {pin_tag}, and fsp {own} writes the files and pins of {own_tag}, which the packages at {pin_tag} may not have (a companion that is newer, an API that changed); nothing was written. Move the refs with `fsp upgrade --app` first, or use the fsp of the pin: {launcher}"
        )
    } else {
        format!(
            "this app pins fespalier {pin_tag}, and fsp {own} writes the files and pins of {own_tag}, which the packages at {pin_tag} may not have (a companion that is newer, an API that changed); nothing was written. Move the refs with `fsp upgrade --app` first (the fsp of {pin_tag} has no `fsp add`)"
        )
    }
}

/// The features of `table` by id, for messages.
fn ids(table: &[Recipe]) -> String {
    table.iter().map(|r| r.id).collect::<Vec<_>>().join(", ")
}

/// The lower bound of `environment: <key>:` (`">=3.35.0"`, `^3.9.0`), when there is one.
fn floor_of(pubspec: &Value, key: &str) -> Option<FlutterVersion> {
    let text = pubspec.get("environment")?.get(key)?.as_str()?.trim();
    // `>=3.0.0 <4.0.0`, `>= 3.0.0`, `>3.0.0` and `^3.9.0` all start with their lower bound; a
    // range that starts with `<` (or `any`) has none.
    let bound = text
        .strip_prefix(">=")
        .or_else(|| text.strip_prefix('>'))
        .or_else(|| text.strip_prefix('^'))
        .unwrap_or(text);
    let bound = bound.split_whitespace().next()?;
    FlutterVersion::parse(bound.trim_matches('"'))
}

fn yaml(text: &str) -> Value {
    serde_yaml_ng::from_str(text).unwrap_or(Value::Null)
}

/// A key of `fespalier:` as the pubspec has it.
fn config_value<'v>(pubspec: &'v Value, key: &str) -> Option<&'v Value> {
    pubspec.get("fespalier")?.get(key)
}

fn listed(pubspec: &Value, section: &str, name: &str) -> bool {
    pubspec.get(section).and_then(|s| s.get(name)).is_some()
}

/// Whether the app has `recipe`: its packages under `dependencies:`, its test-only ones under
/// `dev_dependencies:` or `dependencies:` (since 0.24.1, as the edits leave one listed in either
/// alone), its `fespalier:` keys, and every file it writes. A recipe with none of these has nothing
/// to tell it by, so it is never present. The files it takes out of the base app (`replaces`) tell
/// nothing: one that is not there may never have been.
fn has(recipe: &Recipe, pubspec: &Value, files: &BTreeMap<String, String>) -> bool {
    let dep = |name: &str| listed(pubspec, "dependencies", name);
    let dev = |name: &str| listed(pubspec, "dev_dependencies", name);
    let marks = recipe.companions.len()
        + recipe.third_party.len()
        + recipe.dev_third_party.len()
        + recipe.config.len()
        + recipe.files.len();
    marks > 0
        && recipe.companions.iter().all(|c| dep(c))
        && recipe.third_party.iter().all(|t| dep(t.name))
        && recipe
            .dev_third_party
            .iter()
            .all(|t| dev(t.name) || dep(t.name))
        && recipe.config.iter().all(|line| {
            line.split_once(": ")
                .is_some_and(|(k, v)| config_value(pubspec, k) == Some(&yaml(v)))
        })
        && recipe
            .files
            .iter()
            .all(|(_, path)| files.contains_key(*path))
}

/// The features of `table` that the app has, in the table's order.
#[must_use]
pub fn present<'t>(
    table: &'t [Recipe],
    pubspec: &Value,
    files: &BTreeMap<String, String>,
) -> Vec<&'t Recipe> {
    table.iter().filter(|r| has(r, pubspec, files)).collect()
}

/// The value of a third-party dependency, as `fsp create` writes it.
fn third_party_body(tp: &ThirdParty) -> Body {
    match tp.source {
        Source::Range(range) => Body::Inline(format!("\"{range}\"")),
        Source::Sdk(sdk) => Body::Block(vec![format!("sdk: {sdk}")]),
        Source::Git { url, commit } => Body::Block(vec![
            "git:".to_string(),
            format!("  url: {url}"),
            format!("  ref: {commit}"),
        ]),
    }
}

fn third_party_shown(tp: &ThirdParty) -> String {
    match tp.source {
        Source::Range(range) => format!("{} {range}", tp.name),
        Source::Sdk(sdk) => format!("{} (the {sdk} SDK)", tp.name),
        Source::Git { url, commit } => format!("{} ({url} at {commit})", tp.name),
    }
}

/// The comment `fsp create` writes above `fespalier:`.
const CONFIG_COMMENT: &str =
    "# Read by the `fsp` generator; docs/configuration.md lists every key.";

/// The comment above a `dependency_overrides:` that `fsp add` makes for a checkout's packages.
const OVERRIDES_COMMENT: &str = "# The packages depend on each other by git; here they all come from the checkout fespalier comes from.";

/// Whether the app has `test/routes/setup.dart` once the plan is written.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Setup {
    /// It has none, and the plan makes none: `fsp test` skips a guarded route by itself.
    Absent,
    /// It was there already (the app's own, or `fsp create`'s for the features it had).
    Present,
    /// The plan writes it, for a feature with `smoke_overrides`.
    Made,
}

/// What [`pubspec_edits`] decides.
struct Edits {
    /// The edits of `pubspec.yaml`.
    pubspec: Vec<Edit>,
    /// The lines that say them.
    changes: Vec<String>,
    /// The edits of `pubspec_overrides.yaml`, and the lines that say them.
    overrides: Vec<Edit>,
    overrides_changes: Vec<String>,
    notes: Vec<String>,
}

/// The pubspec edits for `wanted` on an app that has `all` once they are in. A checkout's overrides
/// go to `pubspec_overrides.yaml` when `in_overrides_file` (the app keeps them there).
fn pubspec_edits(
    pubspec: &Value,
    origin: &Origin,
    overridden: &dyn Fn(&str) -> bool,
    in_overrides_file: bool,
    wanted: &[&Recipe],
    all: &[&Recipe],
    setup: Setup,
) -> Edits {
    let mut edits = vec![];
    let mut changes = vec![];
    let mut notes = vec![];
    let (mut file_edits, mut file_changes) = (vec![], vec![]);
    let dep = |name: &str| listed(pubspec, "dependencies", name);
    let dev = |name: &str| listed(pubspec, "dev_dependencies", name);

    let mut companions: Vec<&str> = wanted
        .iter()
        .flat_map(|r| r.companions.iter().copied())
        .collect();
    companions.sort_unstable();
    companions.dedup();
    for name in &companions {
        if !dep(name) && dev(name) {
            notes.push(format!(
                "{name} is under dev_dependencies:, and the feature needs it under dependencies: move it there"
            ));
        } else if !dep(name) {
            edits.push(Edit::insert(
                &["dependencies"],
                name,
                Body::Block(origin.lines(name)),
                Place::Sorted,
            ));
            changes.push(format!("dependencies: {name} ({})", origin.describe(name)));
        }
    }
    let mut seen: Vec<&str> = vec![];
    for tp in wanted.iter().flat_map(|r| r.third_party.iter()) {
        if seen.contains(&tp.name) {
            continue;
        }
        seen.push(tp.name);
        if let Some(have) = pubspec.get("dependencies").and_then(|d| d.get(tp.name)) {
            if let Source::Range(range) = tp.source
                && have.as_str().is_some_and(|h| h != range)
            {
                notes.push(format!(
                    "kept {}: {} (the feature asks for {range})",
                    tp.name,
                    have.as_str().unwrap_or_default()
                ));
            }
            continue;
        }
        if dev(tp.name) {
            notes.push(format!(
                "{} is under dev_dependencies:, and the feature needs it under dependencies: move it there",
                tp.name
            ));
            continue;
        }
        edits.push(Edit::insert(
            &["dependencies"],
            tp.name,
            third_party_body(tp),
            Place::Sorted,
        ));
        changes.push(format!("dependencies: {}", third_party_shown(tp)));
    }
    let mut seen: Vec<&str> = vec![];
    for tp in wanted.iter().flat_map(|r| r.dev_third_party.iter()) {
        if seen.contains(&tp.name) || dep(tp.name) || dev(tp.name) {
            continue;
        }
        seen.push(tp.name);
        edits.push(Edit::insert(
            &["dev_dependencies"],
            tp.name,
            third_party_body(tp),
            Place::Sorted,
        ));
        changes.push(format!("dev_dependencies: {}", third_party_shown(tp)));
    }
    // A checkout's packages depend on each other by git: each one the new companions reach, and
    // fespalier, is overridden with its folder, as `fsp create --local-packages` does.
    if let Origin::Path { root } = origin
        && !companions.is_empty()
    {
        let mut needed = companion_closure(&companions);
        needed.push("fespalier".to_string());
        needed.sort();
        needed.dedup();
        let missing: Vec<&String> = needed.iter().filter(|n| !overridden(n)).collect();
        let (into, said) = if in_overrides_file {
            (&mut file_edits, &mut file_changes)
        } else {
            (&mut edits, &mut changes)
        };
        if !missing.is_empty()
            && !in_overrides_file
            && pubspec.get("dependency_overrides").is_none()
        {
            into.push(
                Edit::insert(&[], "dependency_overrides", Body::Block(vec![]), Place::End)
                    .with_comments(vec![OVERRIDES_COMMENT.to_string()]),
            );
        }
        for name in missing {
            into.push(Edit::insert(
                &["dependency_overrides"],
                name,
                Body::Block(vec![format!("path: {root}/{name}")]),
                Place::Sorted,
            ));
            said.push(format!("dependency_overrides: {name} (path {root}/{name})"));
        }
    }

    let mut config: Vec<Edit> = vec![];
    let mut seen: Vec<&str> = vec![];
    for line in wanted.iter().flat_map(|r| r.config.iter().copied()) {
        let Some((key, value)) = line.split_once(": ") else {
            continue;
        };
        if seen.contains(&key) {
            continue;
        }
        seen.push(key);
        match config_value(pubspec, key) {
            None => {
                config.push(Edit::insert(
                    &["fespalier"],
                    key,
                    Body::Inline(value.to_string()),
                    Place::End,
                ));
                changes.push(format!("fespalier: {key}: {value}"));
            }
            Some(have) if *have == yaml(value) => {}
            Some(have) => {
                config.push(Edit::set(&["fespalier", key], value));
                let was = serde_yaml_ng::to_string(have).unwrap_or_default();
                changes.push(format!("fespalier: {key}: {value} (was {})", was.trim()));
            }
        }
    }
    // The routes `fsp test` cannot open on its own, for the features this plan adds: what the
    // app already lists or has taken out of `skip:` is its own business. A guarded route is listed
    // only when there is a setup file, whose overrides would get it past nothing but its guard
    // (compose::smoke_skip_lines), so a setup file made now also lists the guarded routes of the
    // features the app had, which `fsp test` skipped by itself until then.
    let skipped: Vec<String> = config_value(pubspec, "test")
        .and_then(|t| t.get("skip"))
        .and_then(Value::as_sequence)
        .map(|s| {
            s.iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    let guarded_from = match setup {
        Setup::Absent => &[][..],
        Setup::Present => wanted,
        Setup::Made => all,
    };
    let routes = wanted
        .iter()
        .flat_map(|r| r.startup.smoke_skip.iter())
        .chain(
            guarded_from
                .iter()
                .flat_map(|r| r.startup.smoke_guarded.iter()),
        );
    let mut listed: Vec<&str> = vec![];
    for (route, why) in routes {
        if skipped.iter().any(|s| s == route) || listed.contains(route) {
            continue;
        }
        listed.push(*route);
        config.push(Edit::append(
            &["fespalier", "test", "skip"],
            route,
            Some(format!("# {route} {why}.")),
        ));
        changes.push(format!("fespalier: test: skip: {route}"));
    }
    if !config.is_empty() && pubspec.get("fespalier").is_none() {
        edits.push(
            Edit::insert(&[], "fespalier", Body::Block(vec![]), Place::End)
                .with_comments(vec![CONFIG_COMMENT.to_string()]),
        );
    }
    edits.extend(config);

    let assets: Vec<String> = pubspec
        .get("flutter")
        .and_then(|f| f.get("assets"))
        .and_then(Value::as_sequence)
        .map(|s| {
            s.iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    for asset in wanted.iter().flat_map(|r| r.startup.assets.iter()) {
        if !assets.iter().any(|a| a == asset) {
            edits.push(Edit::append(&["flutter", "assets"], asset, None));
            changes.push(format!("flutter: assets: {asset}"));
        }
    }
    Edits {
        pubspec: edits,
        changes,
        overrides: file_edits,
        overrides_changes: file_changes,
        notes,
    }
}

/// Whether the quote after `before` opens a raw string: an `r` that is no end of a name.
fn is_raw(before: &str) -> bool {
    before
        .strip_suffix('r')
        .is_some_and(|name| !name.ends_with(|c: char| c.is_alphanumeric() || c == '_' || c == '$'))
}

/// The byte length of the Dart string literal that starts `text` (at its quote): a triple-quoted
/// one, an escape, a raw one (`r'...'`, when `raw`) and a `${...}` that holds quotes of its own
/// included. An unterminated one runs to the end.
fn string_len(text: &str, raw: bool) -> usize {
    let quote = &text[..1];
    let delimiter = if text.starts_with(&quote.repeat(3)) {
        quote.repeat(3)
    } else {
        quote.to_string()
    };
    let mut i = delimiter.len();
    while i < text.len() {
        let rest = &text[i..];
        if rest.starts_with(delimiter.as_str()) {
            return i + delimiter.len();
        }
        let Some(c) = rest.chars().next() else { break };
        if !raw && c == '\\' {
            i += 1 + rest[1..].chars().next().map_or(0, char::len_utf8);
        } else if !raw && rest.starts_with("${") {
            i += 2;
            let mut depth = 1;
            while depth > 0 && i < text.len() {
                let inner = &text[i..];
                match inner.chars().next() {
                    Some('\'' | '"') => i += string_len(inner, is_raw(&text[..i])),
                    Some('{') => {
                        depth += 1;
                        i += 1;
                    }
                    Some('}') => {
                        depth -= 1;
                        i += 1;
                    }
                    Some(other) => i += other.len_utf8(),
                    None => break,
                }
            }
        } else {
            i += c.len_utf8();
        }
    }
    text.len()
}

/// Dart as `dart format` leaves its meaning: no white space outside strings and comments, no comma
/// before a closing bracket. A string stays as it is, a `//` comment keeps the line break that
/// ends it (joined onto the next line it would comment that out) and a `/* */` stays as it is.
fn dart_shape(text: &str) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(c) = rest.chars().next() {
        let len = if rest.starts_with("//") {
            let end = rest.find('\n').unwrap_or(rest.len());
            out.push_str(rest[..end].trim_end());
            out.push('\n');
            end
        } else if rest.starts_with("/*") {
            let end = rest.find("*/").map_or(rest.len(), |i| i + 2);
            out.push_str(&rest[..end]);
            end
        } else if matches!(c, '\'' | '"') {
            let end = string_len(rest, is_raw(&text[..text.len() - rest.len()]));
            out.push_str(&rest[..end]);
            end
        } else {
            if matches!(c, ')' | ']' | '}') && out.ends_with(',') {
                out.pop();
            }
            if !c.is_whitespace() {
                out.push(c);
            }
            c.len_utf8()
        };
        rest = &rest[len..];
    }
    out
}

/// Whether the file at `path` is `fsp create`'s: the same text, or, for Dart, the same but for
/// what `dart format` changes (white space outside strings and comments, and the comma after a
/// last argument or element), since `fsp add` formats what it writes the way the app formats its
/// own code. The one meaning this equates is a record of one field, `(x,)` and `(x)`.
#[must_use]
pub fn same_file(path: &str, now: &str, ours: &str) -> bool {
    if !path.ends_with(".dart") {
        return now == ours;
    }
    dart_shape(now) == dart_shape(ours)
}

/// The lines of `old` and `new` that differ, with two lines around each change: `+ ` added,
/// `- ` removed, `  ` kept, and `...` between two changes that are apart.
#[must_use]
pub fn diff(old: &str, new: &str) -> String {
    let a: Vec<&str> = old.lines().collect();
    let b: Vec<&str> = new.lines().collect();
    if a == b {
        return String::new();
    }
    // The longest common subsequence, from the end.
    let mut lcs = vec![vec![0usize; b.len() + 1]; a.len() + 1];
    for i in (0..a.len()).rev() {
        for j in (0..b.len()).rev() {
            lcs[i][j] = if a[i] == b[j] {
                lcs[i + 1][j + 1] + 1
            } else {
                lcs[i + 1][j].max(lcs[i][j + 1])
            };
        }
    }
    let mut ops: Vec<(char, &str)> = vec![];
    let (mut i, mut j) = (0, 0);
    while i < a.len() || j < b.len() {
        if i < a.len() && j < b.len() && a[i] == b[j] {
            ops.push((' ', a[i]));
            i += 1;
            j += 1;
        } else if i < a.len() && (j == b.len() || lcs[i + 1][j] >= lcs[i][j + 1]) {
            ops.push(('-', a[i]));
            i += 1;
        } else {
            ops.push(('+', b[j]));
            j += 1;
        }
    }
    const AROUND: usize = 2;
    let near = |k: usize| {
        let from = k.saturating_sub(AROUND);
        let to = (k + AROUND).min(ops.len() - 1);
        ops[from..=to].iter().any(|(op, _)| *op != ' ')
    };
    let mut out = String::new();
    let mut gap = false;
    for (k, (op, line)) in ops.iter().enumerate() {
        if near(k) {
            if gap && !out.is_empty() {
                out.push_str("  ...\n");
            }
            gap = false;
            let _ = writeln!(out, "{}", format!("{op} {line}").trim_end());
        } else {
            gap = true;
        }
    }
    out
}

/// Decides everything. Refuses, in this order: a pubspec it cannot read, an app it does not write
/// into (`main: manual`, another `app_dir` or `output`), no or an unknown feature, one only
/// `fsp create` makes, pins out of line, a Dart below `fsp create`'s or a Flutter below a
/// feature's, a conflict with a feature the app has, a fespalier at another release than this
/// `fsp` (only when there is something to add), a feature some of whose files are there, and a
/// pubspec it cannot edit safely.
pub fn build(req: &Request, table: &[Recipe]) -> Result<Plan> {
    let value: Value =
        serde_yaml_ng::from_str(req.pubspec).context("pubspec.yaml is not valid YAML")?;
    let read = Pubspec::parse(req.pubspec).context("pubspec.yaml")?;
    let Some(package) = read.name.clone() else {
        bail!("pubspec.yaml has no `name:`");
    };
    let cfg = &read.config;
    if cfg.main == MainMode::Manual {
        bail!(
            "fsp add wires a feature into the generated main() (lib/app/startup.dart, lib/app/app.dart), and this app has `main: manual`; add it by hand: docs/cli.md, \"fsp create\", says what each feature adds"
        );
    }
    if cfg.app_dir != DEFAULT_APP_DIR || cfg.output != DEFAULT_OUTPUT {
        bail!(
            "fsp add writes the files of `fsp create`, which are in {DEFAULT_APP_DIR}/ and import {DEFAULT_OUTPUT}, and this app sets `app_dir:` or `output:`; add the feature by hand: docs/cli.md, \"fsp create\", says what each feature adds"
        );
    }
    if req.features.is_empty() {
        bail!(
            "fsp add needs a feature: {} (`fsp create --list-features` says what each adds)",
            ids(table)
        );
    }
    for wanted in req.features {
        if wanted == ALL {
            bail!(
                "`{ALL}` is for `fsp create`; fsp add takes features by name: {}",
                ids(table)
            );
        }
        if !table.iter().any(|r| r.id == wanted) {
            bail!(
                "unknown feature `{wanted}`; the features are {} (`fsp create --list-features` says what each adds)",
                ids(table)
            );
        }
    }
    let (asked, mut notes) = resolve_features(table, req.features)?;
    for recipe in &asked {
        if !recipe.replaces.is_empty() {
            bail!(
                "`{}` takes the place of {}, which are the app's own: only `fsp create` makes it (`fsp create --template tabs`)",
                recipe.id,
                recipe.replaces.join(", ")
            );
        }
    }
    let pins = pins::read(&value).map_err(|e| anyhow!(e))?;
    let out_of_line = pins.out_of_line();
    if !out_of_line.is_empty() {
        bail!(
            "fsp add pins a new package as fespalier is ({}), and these are pinned otherwise:\n  {}\nPin them as fespalier is (`fsp upgrade --app` moves refs together), then run fsp add again",
            pins.fespalier.describe("fespalier"),
            out_of_line.join("\n  ")
        );
    }
    if let Some(dart) = floor_of(&value, "sdk")
        && !dart.at_least(BASE_DART)
    {
        bail!(
            "fsp add writes the files of `fsp create`, which are Dart {BASE_DART} (`sdk: ^{BASE_DART}.0`), and pubspec.yaml allows Dart {dart} (`environment: sdk:`); raise that to ^{BASE_DART}.0 first (Flutter {} comes with Dart {BASE_DART})",
            crate::create::plan::BASE_FLOOR
        );
    }
    if let Some(floor) = floor_of(&value, "flutter") {
        for recipe in &asked {
            if !floor.at_least(recipe.flutter_floor) {
                bail!(
                    "`{}` needs Flutter {} or newer, and pubspec.yaml allows Flutter {floor} (`environment: flutter:`); raise that first",
                    recipe.id,
                    recipe.flutter_floor
                );
            }
        }
    }

    let files = req.files;
    let had = present(table, &value, files);
    let mut wanted: Vec<&Recipe> = vec![];
    for recipe in asked {
        if had.iter().any(|r| r.id == recipe.id) {
            notes.push(format!("`{}` is in the app already", recipe.id));
        } else {
            wanted.push(recipe);
        }
    }
    for recipe in &wanted {
        for other in &had {
            if recipe.conflicts.contains(&other.id) || other.conflicts.contains(&recipe.id) {
                bail!(
                    "`{}` and `{}` cannot be combined, and the app has `{}`",
                    recipe.id,
                    other.id,
                    other.id
                );
            }
        }
    }
    let ctx = had;
    let all: Vec<&Recipe> = table
        .iter()
        .filter(|r| ctx.iter().chain(&wanted).any(|w| w.id == r.id))
        .collect();
    let mut plan = Plan {
        package: package.clone(),
        features: wanted.iter().map(|r| r.id).collect(),
        present: ctx.iter().map(|r| r.id).collect(),
        notes,
        pubspec: None,
        changes: vec![],
        overrides: None,
        files: vec![],
        by_hand: vec![],
        android_min_sdk: wanted
            .iter()
            .filter_map(|r| r.startup.android_min_sdk)
            .max(),
    };
    if wanted.is_empty() {
        return Ok(plan);
    }
    // The files and the pins are those of this fsp's release: an app that pins another one would
    // get a package its release does not have, or files that use an API it lacks.
    if let Origin::Git { reference, .. } = &pins.fespalier
        && let Some(pin) = Version::parse(reference)
        && let Some(own) = Version::parse(env!("CARGO_PKG_VERSION"))
        && pin != own
    {
        bail!("{}", another_release(pin, own, req.features));
    }

    // The feature's own files: all of them, or none when all are there; some is refused.
    for recipe in &wanted {
        let there: Vec<&str> = recipe
            .files
            .iter()
            .map(|(_, path)| *path)
            .filter(|path| files.contains_key(*path))
            .collect();
        if !there.is_empty() && there.len() < recipe.files.len() {
            bail!(
                "`{}` writes {}, and {} {} there already; fsp add never writes over a file. Move {}, or add the feature by hand: docs/cli.md, \"fsp create\", says what it adds",
                recipe.id,
                recipe
                    .files
                    .iter()
                    .map(|(_, p)| *p)
                    .collect::<Vec<_>>()
                    .join(", "),
                there.join(", "),
                if there.len() == 1 { "is" } else { "are" },
                if there.len() == 1 { "it" } else { "them" },
            );
        }
    }
    let ids_of =
        |recipes: &[&Recipe]| -> Vec<&'static str> { recipes.iter().map(|r| r.id).collect() };
    let (ids_ctx, ids_all) = (ids_of(&ctx), ids_of(&all));
    let render = |template: &str, features: &[&str]| {
        templates::render(
            template,
            serde_json::json!({ "package": package, "features": features }),
        )
    };
    for recipe in &wanted {
        if recipe
            .files
            .iter()
            .all(|(_, path)| files.contains_key(*path))
        {
            continue;
        }
        for (template, path) in recipe.files {
            plan.files.push(File {
                path: (*path).to_string(),
                content: render(template, &ids_all),
                write: Write::New,
            });
        }
    }
    // Files of fsp's that follow the set of features: a feature's own (a test that starts the
    // whole app knows the others), then the shared ones.
    let mut follow: Vec<(String, Option<String>, Option<String>)> = vec![];
    for recipe in &ctx {
        for (template, path) in recipe.files {
            follow.push((
                (*path).to_string(),
                Some(render(template, &ids_ctx)),
                Some(render(template, &ids_all)),
            ));
        }
    }
    let starter = init::starter("app", &package);
    let main = templates::render(
        "create/main.dart",
        serde_json::json!({ "package": package }),
    );
    follow.push((
        SHARED[0].to_string(),
        compose::startup_dart(&package, &ctx)?,
        compose::startup_dart(&package, &all)?,
    ));
    follow.push((
        SHARED[1].to_string(),
        Some(compose::app_dart(&package, &starter, &ctx)?),
        Some(compose::app_dart(&package, &starter, &all)?),
    ));
    follow.push((
        SHARED[2].to_string(),
        Some(compose::main_dart(&main, &ctx)),
        Some(compose::main_dart(&main, &all)),
    ));
    follow.push((
        SHARED[3].to_string(),
        compose::smoke_setup(&package, &ctx),
        compose::smoke_setup(&package, &all),
    ));
    for (path, before, after) in follow {
        let Some(after) = after else { continue };
        if before.as_ref() == Some(&after) {
            continue;
        }
        match (files.get(&path), &before) {
            (None, None) => plan.files.push(File {
                path,
                content: after,
                write: Write::New,
            }),
            (Some(now), Some(before)) if same_file(&path, now, before) => plan.files.push(File {
                path,
                content: after,
                write: Write::Update,
            }),
            (now, before) => plan.by_hand.push(ByHand {
                change: diff(before.as_deref().unwrap_or_default(), &after),
                why: if now.is_some() {
                    "it is not what fsp create writes for the features the app has, so it is yours"
                } else {
                    "it is not there, though the features the app has would have written it"
                },
                path,
            }),
        }
    }

    let setup = if plan
        .files
        .iter()
        .any(|f| f.path == SHARED[3] && f.write == Write::New)
    {
        Setup::Made
    } else if files.contains_key(SHARED[3]) {
        Setup::Present
    } else {
        Setup::Absent
    };
    // pub reads the overrides of `pubspec_overrides.yaml` in place of the pubspec's when that file
    // has the key, and, in a pub workspace, those of its root with the app's own (since 0.23.1).
    let file: Option<Value> = match req.overrides {
        Some(text) if !text.trim().is_empty() => Some(
            serde_yaml_ng::from_str(text).context("pubspec_overrides.yaml is not valid YAML")?,
        ),
        _ => None,
    };
    let in_file = file.as_ref().and_then(|f| f.get("dependency_overrides"));
    let overridden = |name: &str| {
        req.workspace_overrides.iter().any(|n| n == name)
            || match in_file {
                Some(section) => section.get(name).is_some(),
                None => pins.has("dependency_overrides", name),
            }
    };
    let edits = pubspec_edits(
        &value,
        &pins.fespalier,
        &overridden,
        in_file.is_some(),
        &wanted,
        &all,
        setup,
    );
    plan.notes.extend(edits.notes);
    let edit = |file: &str, text: &str, list: &[Edit]| {
        pubspec_edit::apply(text, list).map_err(|e| {
            anyhow!(
                "could not edit {file} safely ({e}), so nothing was written. Make this change by hand, then run fsp add again:\n  {}",
                e.edit.by_hand().replace('\n', "\n  ")
            )
        })
    };
    let edited = edit("pubspec.yaml", req.pubspec, &edits.pubspec)?;
    if edited != req.pubspec {
        Pubspec::parse(&edited).context("the pubspec.yaml fsp add would write does not check")?;
        plan.pubspec = Some(edited);
    }
    plan.changes = edits.changes;
    if !edits.overrides.is_empty() {
        let before = req.overrides.unwrap_or_default();
        plan.overrides = Some(Overrides {
            after: edit(OVERRIDES, before, &edits.overrides)?,
            before: before.to_string(),
            changes: edits.overrides_changes,
        });
    }
    Ok(plan)
}

impl Plan {
    /// The plan as text: what changes, the commands, then the pubspec's change and every file in
    /// full. `--dry-run` prints it and the goldens pin it. `pubspec` is the pubspec as it is;
    /// `commands` are what runs after the files are written.
    #[must_use]
    pub fn describe(&self, pubspec: &str, commands: &[String]) -> String {
        let mut out = String::new();
        let _ = writeln!(
            out,
            "add {} to {} (it has: {})",
            self.features.join(", "),
            self.package,
            if self.present.is_empty() {
                "none of the features".to_string()
            } else {
                self.present.join(", ")
            }
        );
        for note in &self.notes {
            let _ = writeln!(out, "note   {note}");
        }
        if self.pubspec.is_some() {
            let _ = writeln!(out, "edit   pubspec.yaml");
            for change in &self.changes {
                let _ = writeln!(out, "         {change}");
            }
        }
        if let Some(overrides) = &self.overrides {
            let _ = writeln!(out, "edit   {OVERRIDES}");
            for change in &overrides.changes {
                let _ = writeln!(out, "         {change}");
            }
        }
        for file in &self.files {
            let _ = writeln!(out, "{:<6} {}", file.write.word(), file.path);
        }
        for hand in &self.by_hand {
            let _ = writeln!(out, "hand   {} ({})", hand.path, hand.why);
        }
        if let Some(min) = self.android_min_sdk {
            let _ = writeln!(
                out,
                "edit   {}: minSdk is at least {min}, when the app has it",
                crate::create::plan::ANDROID_GRADLE
            );
        }
        for command in commands {
            let _ = writeln!(out, "run    {command}");
        }
        if let Some(new) = &self.pubspec {
            let _ = write!(out, "\n=== pubspec.yaml (edit)\n{}", diff(pubspec, new));
        }
        if let Some(overrides) = &self.overrides {
            let _ = write!(
                out,
                "\n=== {OVERRIDES} (edit)\n{}",
                diff(&overrides.before, &overrides.after)
            );
        }
        for file in &self.files {
            let _ = write!(
                out,
                "\n=== {} ({})\n{}",
                file.path,
                file.write.word(),
                file.content
            );
        }
        for hand in &self.by_hand {
            let _ = write!(
                out,
                "\n=== {} (by hand: {})\n{}",
                hand.path, hand.why, hand.change
            );
        }
        out
    }
}
