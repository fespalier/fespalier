//! `fsp size`: the web build's JavaScript per deferred route, and byte budgets for CI.
//!
//! `flutter build web` splits each deferred page (see `deferred` in `route.dart`) into
//! `main.dart.js_N.part.js` files, and dart2js writes the table that says which route loads
//! which part into `main.dart.js` itself, in every build mode:
//!
//! ```text
//! deferredLibraryParts:{_i7:[0,1],_i14:[0,2]},deferredPartUris:["main.dart.js_2.part.js","main.dart.js_1.part.js","main.dart.js_3.part.js"]
//! ```
//!
//! The keys are the load ids, which are the import prefixes of the generated `app.g.dart`
//! (`import 'app/checkout/page.dart' deferred as _i7;`), and a page's prefix is `_i{n}` for the
//! `n` its `Widget.import` carries, the same `n` the template writes. The values index
//! `deferredPartUris`, whose order is not the file numbering.
//!
//! A route's **own** bytes are the parts only it loads, its **shared** bytes the parts other
//! deferred routes load too, and its **total** is both: what a first visit downloads when nothing
//! else is loaded. Sizes are bytes on disk, uncompressed, which is deterministic for one Flutter
//! version. Code of routes that are not deferred is in `main.dart.js`.
//!
//! A build made from other routes than the ones on disk is caught two ways: the `_iN` keys of the
//! table must be exactly the prefixes the routes defer now (an error), and `main.dart.js` older
//! than the generated file is a warning.
//!
//! Like `fsp links` and `fsp maestro`, this reads its own config section (`size:`) and checks it
//! only when the command runs, so a mistake in it never stops `fsp gen`.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Result, bail};
use serde_json::json;

use crate::config::{Config, DEFAULT_SIZE_BUILD, Size};
use crate::emit::rel;
use crate::resolve::{self, App};
use crate::scan::Kind;
use crate::{analyze, diag, plural};

/// dart2js's table of deferred parts, as `main.dart.js` has it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Table {
    /// The part file of each index, in dart2js's order.
    pub uris: Vec<String>,
    /// For each load id (an import prefix), the indexes into `uris` it loads, in dart2js's order.
    pub libs: Vec<(String, Vec<usize>)>,
}

/// `main.dart.js` has a deferred-parts table that cannot be read.
#[derive(Debug, PartialEq, Eq)]
pub struct Unreadable;

/// A cursor over the text of a JavaScript object or array literal.
struct Cursor<'a> {
    text: &'a [u8],
    at: usize,
}

impl Cursor<'_> {
    fn skip_space(&mut self) {
        while self.text.get(self.at).is_some_and(u8::is_ascii_whitespace) {
            self.at += 1;
        }
    }

    /// Skips space, then takes `byte` if it is next.
    fn eat(&mut self, byte: u8) -> bool {
        self.skip_space();
        let found = self.text.get(self.at) == Some(&byte);
        if found {
            self.at += 1;
        }
        found
    }

    fn expect(&mut self, byte: u8) -> Result<(), Unreadable> {
        if self.eat(byte) {
            Ok(())
        } else {
            Err(Unreadable)
        }
    }

    /// A single- or double-quoted string; a backslash takes the next character as it is.
    fn string(&mut self) -> Result<String, Unreadable> {
        self.skip_space();
        let quote = *self.text.get(self.at).ok_or(Unreadable)?;
        if quote != b'"' && quote != b'\'' {
            return Err(Unreadable);
        }
        self.at += 1;
        let mut out = vec![];
        loop {
            let b = *self.text.get(self.at).ok_or(Unreadable)?;
            self.at += 1;
            match b {
                b if b == quote => break,
                b'\\' => {
                    out.push(*self.text.get(self.at).ok_or(Unreadable)?);
                    self.at += 1;
                }
                b => out.push(b),
            }
        }
        String::from_utf8(out).map_err(|_| Unreadable)
    }

    /// An object key: an identifier (`_i7`) or a quoted string.
    fn key(&mut self) -> Result<String, Unreadable> {
        self.skip_space();
        let start = self.at;
        let first = *self.text.get(start).ok_or(Unreadable)?;
        if first == b'"' || first == b'\'' {
            return self.string();
        }
        let ident = |b: u8| b.is_ascii_alphanumeric() || b == b'_' || b == b'$';
        if first.is_ascii_digit() || !ident(first) {
            return Err(Unreadable);
        }
        while self.text.get(self.at).is_some_and(|b| ident(*b)) {
            self.at += 1;
        }
        String::from_utf8(self.text[start..self.at].to_vec()).map_err(|_| Unreadable)
    }

    fn index(&mut self) -> Result<usize, Unreadable> {
        self.skip_space();
        let start = self.at;
        while self.text.get(self.at).is_some_and(u8::is_ascii_digit) {
            self.at += 1;
        }
        std::str::from_utf8(&self.text[start..self.at])
            .ok()
            .and_then(|n| n.parse().ok())
            .ok_or(Unreadable)
    }

    /// `[a, b, c]` of whatever `item` reads, after the `[`; a trailing comma is fine.
    fn list<T>(
        &mut self,
        mut item: impl FnMut(&mut Self) -> Result<T, Unreadable>,
    ) -> Result<Vec<T>, Unreadable> {
        let mut out = vec![];
        loop {
            if self.eat(b']') {
                return Ok(out);
            }
            out.push(item(self)?);
            if !self.eat(b',') {
                self.expect(b']')?;
                return Ok(out);
            }
        }
    }
}

/// Where the value of `name` starts: the one place `name` is followed by `:` and `opener`, with
/// whitespace and a closing quote allowed in between. `Ok(None)` when it appears nowhere that way;
/// a use of it (`deferredLibraryParts[a]`) is not followed by `:`.
fn value_of(js: &str, name: &str, opener: u8) -> Result<Option<usize>, Unreadable> {
    let bytes = js.as_bytes();
    let ident = |b: u8| b.is_ascii_alphanumeric() || b == b'_' || b == b'$';
    let mut found = vec![];
    for (at, _) in js.match_indices(name) {
        if at > 0 && ident(bytes[at - 1]) {
            continue;
        }
        let mut c = Cursor {
            text: bytes,
            at: at + name.len(),
        };
        if matches!(bytes.get(c.at), Some(b'"' | b'\'')) {
            c.at += 1;
        }
        if c.eat(b':') && c.eat(opener) {
            found.push(c.at);
        }
    }
    match found.as_slice() {
        [] => Ok(None),
        [at] => Ok(Some(*at)),
        _ => Err(Unreadable),
    }
}

/// Reads dart2js's table of deferred parts out of `main.dart.js`. `Ok(None)` when it has none:
/// the app loads no deferred code.
pub fn parse_table(js: &str) -> Result<Option<Table>, Unreadable> {
    let libs = value_of(js, "deferredLibraryParts", b'{')?;
    let uris = value_of(js, "deferredPartUris", b'[')?;
    let (libs, uris) = match (libs, uris) {
        (None, None) => return Ok(None),
        (Some(l), Some(u)) => (l, u),
        _ => return Err(Unreadable),
    };
    let mut c = Cursor {
        text: js.as_bytes(),
        at: uris,
    };
    let uris = c.list(Cursor::string)?;
    let mut c = Cursor {
        text: js.as_bytes(),
        at: libs,
    };
    let mut table = Table { uris, libs: vec![] };
    while !c.eat(b'}') {
        let key = c.key()?;
        c.expect(b':')?;
        c.expect(b'[')?;
        let parts = c.list(Cursor::index)?;
        if parts.iter().any(|i| *i >= table.uris.len()) || table.libs.iter().any(|(k, _)| *k == key)
        {
            return Err(Unreadable);
        }
        table.libs.push((key, parts));
        if !c.eat(b',') {
            c.expect(b'}')?;
            break;
        }
    }
    Ok(Some(table))
}

/// `3145728` as `3.0 MB`, `5982` as `5.8 KB`, `900` as `900 B`.
fn human(n: u64) -> String {
    if n >= 1_048_576 {
        format!("{:.1} MB", to_f64(n) / 1_048_576.0)
    } else if n >= 1024 {
        format!("{:.1} KB", to_f64(n) / 1024.0)
    } else {
        format!("{n} B")
    }
}

#[allow(
    clippy::cast_precision_loss,
    reason = "a file size, far below 2^52, shown with one decimal"
)]
fn to_f64(n: u64) -> f64 {
    n as f64
}

/// `5259 B (5.1 KB)`; below 1 KB just `900 B`.
fn size_text(n: u64) -> String {
    if n >= 1024 {
        format!("{n} B ({})", human(n))
    } else {
        format!("{n} B")
    }
}

/// One deferred route's share of the build.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RouteSize {
    /// `/products/:id`.
    pub pattern: String,
    /// `ProductRoute`.
    pub class: String,
    /// The page, relative to the app folder: `products/$id/page.dart`.
    pub file: String,
    /// The page, relative to the project root: `lib/app/products/$id/page.dart`.
    pub project_file: String,
    /// The part files it loads, in dart2js's order.
    pub parts: Vec<String>,
    /// The bytes of the parts only this route loads.
    pub own: u64,
    /// The bytes of the parts other deferred routes load too.
    pub shared: u64,
    pub budget: Option<u64>,
}

impl RouteSize {
    #[must_use]
    pub fn total(&self) -> u64 {
        self.own + self.shared
    }

    fn over(&self) -> Option<u64> {
        self.budget
            .and_then(|b| self.total().checked_sub(b))
            .filter(|n| *n > 0)
    }
}

/// One `main.dart.js_N.part.js`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PartSize {
    pub file: String,
    pub bytes: u64,
    /// The patterns of the deferred routes that load it; empty for a part only another
    /// deferred import loads.
    pub routes: Vec<String>,
    /// The load ids that load it, as the table has them.
    pub keys: Vec<String>,
}

/// Everything `fsp size` reports.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Report {
    pub main_bytes: u64,
    pub main_budget: Option<u64>,
    /// The deferred routes, in the order of the route table.
    pub routes: Vec<RouteSize>,
    /// Every part, in dart2js's order.
    pub parts: Vec<PartSize>,
    /// How many routes there are, deferred or not.
    pub route_count: usize,
}

impl Report {
    fn main_over(&self) -> Option<u64> {
        self.main_budget
            .and_then(|b| self.main_bytes.checked_sub(b))
            .filter(|n| *n > 0)
    }

    /// `main.dart.js` and the patterns that are over their budget, in report order.
    #[must_use]
    pub fn over_budget(&self) -> Vec<String> {
        let mut over = vec![];
        if self.main_over().is_some() {
            over.push("main.dart.js".to_string());
        }
        over.extend(
            self.routes
                .iter()
                .filter(|r| r.over().is_some())
                .map(|r| r.pattern.clone()),
        );
        over
    }

    fn budgeted(&self) -> bool {
        self.main_budget.is_some() || self.routes.iter().any(|r| r.budget.is_some())
    }

    /// The report as aligned text: `main.dart.js`, each deferred route, then the shared parts and
    /// the parts no route loads.
    #[must_use]
    pub fn text(&self) -> Vec<String> {
        let budget = |bytes: u64, budget: Option<u64>| match budget {
            None => String::new(),
            Some(b) if bytes > b => {
                format!("OVER budget {} by {} B", human(b), bytes - b)
            }
            Some(b) => format!("budget {}", human(b)),
        };
        let mut rows: Vec<Vec<String>> = vec![vec![
            "main.dart.js".into(),
            String::new(),
            String::new(),
            size_text(self.main_bytes),
            budget(self.main_bytes, self.main_budget),
        ]];
        for r in &self.routes {
            rows.push(vec![
                r.pattern.clone(),
                r.class.clone(),
                r.file.clone(),
                size_text(r.total()),
                format!("own {} B, shared {} B", r.own, r.shared),
                budget(r.total(), r.budget),
            ]);
        }
        let mut out = pad(&rows);
        let mut parts: Vec<Vec<String>> = vec![];
        for p in &self.parts {
            let (kind, what) = match p.routes.len() {
                0 if p.keys.is_empty() => ("other", "loaded by no deferred import".to_string()),
                0 => (
                    "other",
                    format!(
                        "deferred imports {}",
                        p.keys
                            .iter()
                            .map(|k| format!("`{k}`"))
                            .collect::<Vec<_>>()
                            .join(", ")
                    ),
                ),
                1 => continue,
                _ => ("shared", p.routes.join(", ")),
            };
            parts.push(vec![
                kind.into(),
                p.file.clone(),
                format!("{}: {what}", size_text(p.bytes)),
            ]);
        }
        out.extend(pad(&parts));
        out
    }

    /// One JSON object per line: `main.dart.js`, each deferred route, then every part.
    #[must_use]
    pub fn json_lines(&self) -> Vec<String> {
        let mut out = vec![
            json!({"kind": "main", "file": "main.dart.js", "bytes": self.main_bytes, "budget": self.main_budget})
                .to_string(),
        ];
        for r in &self.routes {
            out.push(
                json!({
                    "kind": "route",
                    "pattern": r.pattern,
                    "route": r.class,
                    "file": r.project_file,
                    "parts": r.parts,
                    "own": r.own,
                    "shared": r.shared,
                    "bytes": r.total(),
                    "budget": r.budget,
                })
                .to_string(),
            );
        }
        for p in &self.parts {
            out.push(
                json!({"kind": "part", "file": p.file, "bytes": p.bytes, "routes": p.routes})
                    .to_string(),
            );
        }
        out
    }

    /// The success line: how many routes, how many are deferred and in how many parts.
    fn summary(&self) -> String {
        let within = if self.budgeted() && self.over_budget().is_empty() {
            ", within budget"
        } else {
            ""
        };
        format!(
            "✓ size: {}, {} deferred, {}{within}",
            plural(self.route_count, "route"),
            self.routes.len(),
            plural(self.parts.len(), "part"),
        )
    }
}

/// The rows with each column padded to its widest cell and two spaces between; the last column
/// is not padded, and a row ends where its last cell does.
fn pad(rows: &[Vec<String>]) -> Vec<String> {
    let columns = rows.iter().map(Vec::len).max().unwrap_or(0);
    let widths: Vec<usize> = (0..columns)
        .map(|c| {
            rows.iter()
                .filter_map(|r| r.get(c))
                .map(|s| s.chars().count())
                .max()
                .unwrap_or(0)
        })
        .collect();
    rows.iter()
        .map(|row| {
            let line: Vec<String> = row
                .iter()
                .enumerate()
                .map(|(c, cell)| format!("{cell:w$}", w = widths[c]))
                .collect();
            line.join("  ").trim_end().to_string()
        })
        .collect()
}

/// The deferred routes of `app` with the load id (`_i7`) their page's import has.
pub(crate) fn deferred_routes(app: &App) -> Vec<(String, &resolve::Route)> {
    app.routes
        .iter()
        .filter(|r| r.is_route() && r.defers_page())
        .filter_map(|r| r.page.as_ref().map(|p| (format!("_i{}", p.import), r)))
        .collect()
}

/// `_i7`, `_i14`: a load id fespalier gives (`_i` and digits).
fn is_prefix(key: &str) -> bool {
    key.strip_prefix("_i")
        .is_some_and(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()))
}

/// Checks the budgets' routes against the app: each `routes` key is a deferred route.
fn check_budget_routes(app: &App, size: &Size) -> Result<()> {
    for (pattern, _) in &size.routes {
        let Some(route) = app
            .routes
            .iter()
            .find(|r| r.is_route() && resolve::pattern(&r.url) == *pattern)
        else {
            bail!(
                "`fespalier.size.routes`: `{pattern}` is not a route; write the pattern as `fsp routes` prints it (`/products/:id`)"
            );
        };
        if !route.defers_page() {
            bail!(
                "`fespalier.size.routes`: `{pattern}` is not deferred, so its code is in main.dart.js; budget that with `main`"
            );
        }
    }
    Ok(())
}

/// What the build folder is called in a message.
fn shown(build: &str) -> &str {
    if build.is_empty() { "." } else { build }
}

/// The report for `app` from the build in `build_dir` (spelled `shown_build` in messages), and the
/// stale-build warning when there is one. Reads files, prints nothing.
pub fn report(
    app: &App,
    cfg: &Config,
    size: &Size,
    project: &Path,
    build_dir: &Path,
    shown_build: &str,
) -> Result<(Report, Option<String>)> {
    check_budget_routes(app, size)?;
    let main_path = build_dir.join("main.dart.js");
    let js = match fs::read(&main_path) {
        Ok(js) => String::from_utf8_lossy(&js).into_owned(),
        Err(_) => bail!(
            "no main.dart.js in {}: run `flutter build web` first (`fsp size` reads the JavaScript build)",
            shown(shown_build)
        ),
    };
    let output = project.join(&cfg.output);
    let Ok(output_meta) = fs::metadata(&output) else {
        bail!(
            "{} not found: run `fsp gen`, then `flutter build web`",
            cfg.output
        );
    };
    let main_meta = fs::metadata(&main_path)?;
    let warning = match (output_meta.modified(), main_meta.modified()) {
        (Ok(out), Ok(main)) if out > main => Some(format!(
            "warning: {}/main.dart.js is older than {}; if the routes changed since, run `flutter build web` again",
            shown(shown_build),
            cfg.output
        )),
        _ => None,
    };

    let table = parse_table(&js).map_err(|_| {
        anyhow::anyhow!(
            "{}/main.dart.js: can't read dart2js's table of deferred parts (`deferredLibraryParts`, `deferredPartUris`); is it the output of `flutter build web`?",
            shown(shown_build)
        )
    })?;
    let table = table.unwrap_or_default();
    let deferred = deferred_routes(app);

    let found: Vec<&str> = table
        .libs
        .iter()
        .map(|(k, _)| k.as_str())
        .filter(|k| is_prefix(k))
        .collect();
    let found_set: BTreeSet<&str> = found.iter().copied().collect();
    let expected: BTreeSet<&str> = deferred.iter().map(|(p, _)| p.as_str()).collect();
    if found_set != expected {
        let list = |items: Vec<String>| {
            if items.is_empty() {
                "nothing".to_string()
            } else {
                items.join(", ")
            }
        };
        bail!(
            "{}/main.dart.js was built from another {}: it loads deferred code as {}, and the routes now defer {}; run `flutter build web` again",
            shown(shown_build),
            cfg.output,
            list(found.iter().map(|k| format!("`{k}`")).collect()),
            list(
                deferred
                    .iter()
                    .map(|(p, r)| format!("`{p}` ({})", rel(r, Kind::Page)))
                    .collect()
            ),
        );
    }

    let mut bytes: Vec<u64> = vec![];
    for uri in &table.uris {
        match fs::metadata(build_dir.join(uri)) {
            Ok(m) => bytes.push(m.len()),
            Err(_) => bail!(
                "{}/{uri} is missing: the build is incomplete",
                shown(shown_build)
            ),
        }
    }

    // The patterns of the routes that load each part, and the load ids that do.
    let mut loaded_by: Vec<Vec<usize>> = vec![vec![]; table.uris.len()];
    let mut keys: Vec<Vec<String>> = vec![vec![]; table.uris.len()];
    let by_prefix: BTreeMap<&str, usize> = deferred
        .iter()
        .enumerate()
        .map(|(i, (p, _))| (p.as_str(), i))
        .collect();
    for (key, parts) in &table.libs {
        for part in parts {
            if !keys[*part].contains(key) {
                keys[*part].push(key.clone());
                if let Some(route) = by_prefix.get(key.as_str()) {
                    loaded_by[*part].push(*route);
                }
            }
        }
    }

    let budget_of = |pattern: &str| {
        size.routes
            .iter()
            .find(|(p, _)| p == pattern)
            .map(|(_, b)| *b)
            .or(size.route)
    };
    let routes: Vec<RouteSize> = deferred
        .iter()
        .enumerate()
        .map(|(i, (prefix, r))| {
            let pattern = resolve::pattern(&r.url);
            let mut parts: Vec<usize> = vec![];
            for (key, ps) in &table.libs {
                if key == prefix {
                    for p in ps {
                        if !parts.contains(p) {
                            parts.push(*p);
                        }
                    }
                }
            }
            let (mut own, mut shared) = (0, 0);
            for p in &parts {
                if loaded_by[*p] == [i] {
                    own += bytes[*p];
                } else {
                    shared += bytes[*p];
                }
            }
            let file = rel(r, Kind::Page);
            RouteSize {
                budget: budget_of(&pattern),
                class: format!("{}Route", r.name.as_deref().unwrap_or("?")),
                project_file: format!("{}/{file}", cfg.app_dir),
                file,
                parts: parts.iter().map(|p| table.uris[*p].clone()).collect(),
                own,
                shared,
                pattern,
            }
        })
        .collect();
    let parts: Vec<PartSize> = table
        .uris
        .iter()
        .enumerate()
        .map(|(i, file)| PartSize {
            file: file.clone(),
            bytes: bytes[i],
            routes: loaded_by[i]
                .iter()
                .map(|r| routes[*r].pattern.clone())
                .collect(),
            keys: keys[i].clone(),
        })
        .collect();
    let report = Report {
        main_bytes: main_meta.len(),
        main_budget: size.main,
        routes,
        parts,
        route_count: app.routes.iter().filter(|r| r.is_route()).count(),
    };
    Ok((report, warning))
}

/// `fsp size`: the report on stdout (`--json`: JSON lines), the summary on stderr, and with
/// `--check` a failure when a budget is exceeded.
pub fn run(project: &Path, build: Option<&Path>, json: bool, check: bool) -> Result<()> {
    let cfg = Config::load(project)?;
    let size = match &cfg.size {
        Some(raw) => raw.validate()?,
        None => Size {
            build: DEFAULT_SIZE_BUILD.into(),
            main: None,
            route: None,
            routes: vec![],
        },
    };
    if check && !size.has_budgets() {
        bail!(
            "`fsp size --check` checks the budgets in `fespalier.size` (`main`, `route`, `routes`), and there are none"
        );
    }
    let app_dir = project.join(&cfg.app_dir);
    if !app_dir.is_dir() {
        bail!(
            "{} not found (set `fespalier: app_dir:` in pubspec.yaml, or run `fsp init`)",
            app_dir.display()
        );
    }
    let (_, diags, app) = analyze(&app_dir, &cfg)?;
    diag::render(&app_dir, &cfg.app_dir, &diags);
    if diags.has_errors() {
        bail!("{} error(s); no size report", diags.error_count());
    }
    let (build_dir, shown_build): (PathBuf, String) = match build {
        Some(b) => (b.to_path_buf(), b.display().to_string()),
        None => (project.join(&size.build), size.build.clone()),
    };
    let (report, warning) = report(&app, &cfg, &size, project, &build_dir, &shown_build)?;
    if let Some(w) = warning {
        eprintln!("{w}");
    }
    let lines = if json {
        report.json_lines()
    } else {
        report.text()
    };
    for line in lines {
        println!("{line}");
    }
    let over = report.over_budget();
    if check && !over.is_empty() {
        bail!("{} over budget: {}", over.len(), over.join(", "));
    }
    eprintln!("{}", report.summary());
    Ok(())
}
