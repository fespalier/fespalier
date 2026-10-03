//! `fsp test`: a widget smoke test per route, written from the route tree.
//!
//! The one file, `test/routes/routes_test.dart`, has a `testWidgets` for each route. It opens the
//! route at a sample URL with `pumpRouter`, pumps the test's fake clock until the route's page is
//! on screen, and expects exactly one. That proves what a Maestro flow proves (the route exists,
//! its guards let it through, its data loaded, its page was built) in `flutter test`, on the VM,
//! with no device. `fsp test` does not run Flutter: it writes the file, or with `--check`
//! compares it, as `fsp maestro` does for its flows.
//!
//! Everything is a function of the tree, the pubspec and the setup file's two function names:
//! stable order, no dates, so `--check` can compare the file byte for byte. Like `fsp maestro`,
//! this reads its own config section and checks it only when the command runs, so a mistake in
//! it never stops `fsp gen`.
//!
//! The page is found by its `Semantics(identifier: 'route:<pattern>')` when the app sets
//! `semantics_ids: true`, and otherwise by the page's class (`find.byType`), which the test file
//! imports. A function page has no class to find, so without semantics ids it is skipped.
//!
//! Providers are the app's business: `setup.dart` (app-owned, next to the test file by default)
//! may export `overrides(String pattern)`, called once per test for the overrides it boots with,
//! and `app(GoRouter router)`, the app around the router. `fsp test` only reads which of the two
//! it declares. A guarded route has no test unless there are `overrides` to get past its guard.
//!
//! The file starts with [`MARKER`]. `fsp test` never overwrites a file of that name that does not.

use std::collections::HashMap;
use std::fmt::Write as _;
use std::fs;
use std::path::Path;

use anyhow::{Context, Result, bail};

use crate::config::{Config, DEFAULT_TEST_TIMEOUT, Test, parent, relative_dir};
use crate::dart::Function;
use crate::emit::{dart_str, rel};
use crate::maestro::{Skip, guards_above};
use crate::resolve::{self, App};
use crate::samples;
use crate::scan::Kind;
use crate::{analyze, diag, parse_cache, plural};

/// What the first line of the file `fsp test` writes starts with: how it tells its own file from
/// yours.
const MARKER: &str = "// Written by `fsp test`";

/// The name of the one file `fsp test` writes, in the `out` folder.
const FILE: &str = "routes_test.dart";

/// What the app's setup file declares: the two top-level functions `fsp test` looks for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Setup {
    /// Where it is, relative to the project root.
    pub path: String,
    /// `List<Override> overrides(String pattern)`.
    pub overrides: bool,
    /// `Widget app(GoRouter router)`.
    pub app: bool,
}

/// Everything the text of the test file is a function of, besides the route tree.
#[derive(Debug, Clone)]
pub struct TestCx {
    /// The pubspec's `name`: the package the generated file and the pages are imported by.
    pub package: String,
    pub test: Test,
    /// The setup file, when it exists and declares something.
    pub setup: Option<Setup>,
    /// The setup file as the messages name it: the configured path, or the default one.
    pub setup_shown: String,
    /// The config key the samples came from, for the skip text.
    pub samples_key: String,
    /// The checked samples, by folder.
    pub samples: HashMap<usize, Vec<String>>,
}

/// The `lib/`-relative form of a project path, as a `package:` import spells it.
fn in_lib(path: &str) -> &str {
    path.strip_prefix("lib/").unwrap_or(path)
}

/// The import of the setup file from the test file's folder: `setup.dart`, `../helpers/setup.dart`.
fn setup_import(out: &str, setup: &str) -> String {
    let dir = relative_dir(out, parent(setup));
    let name = setup.rsplit('/').next().unwrap_or(setup);
    if dir.is_empty() {
        name.to_string()
    } else {
        format!("{dir}/{name}")
    }
}

/// `import 'uri' as alias;` and its newline. `dart format` (the short style) moves `as` to a line
/// of its own when the line passes 80 columns, so that is how it is written then.
fn import_as(uri: &str, alias: &str) -> String {
    let one = format!("import {uri} as {alias};");
    if one.chars().count() > 80 {
        format!("import {uri}\n    as {alias};\n")
    } else {
        format!("{one}\n")
    }
}

/// Every pattern of `skip` must be the pattern of a route, as `fsp routes` prints it.
pub fn check_skip_list(app: &App, skip: &[String]) -> Result<()> {
    for p in skip {
        let known = app
            .routes
            .iter()
            .filter(|r| r.is_route())
            .any(|r| resolve::pattern(&r.url) == *p);
        if !known {
            bail!(
                "`fespalier.test.skip`: `{p}` is not a route; write the pattern as `fsp routes` prints it (`/products/:id`)"
            );
        }
    }
    Ok(())
}

/// The text of the test file, and the routes that get no test (with the reason), in the order of
/// the route table. Nothing here touches the file system.
pub fn file(app: &App, cfg: &Config, cx: &TestCx) -> Result<(String, Vec<Skip>)> {
    let overrides = cx.setup.as_ref().is_some_and(|s| s.overrides);
    let mut skips: Vec<Skip> = vec![];
    // The guards above each route, and its `testWidgets` line.
    let mut tests: Vec<(Vec<String>, String)> = vec![];
    // The page.dart files imported as `_i0`, `_i1`, ... when pages are found by type.
    let mut pages: Vec<String> = vec![];
    for r in app.routes.iter().filter(|r| r.is_route()) {
        let pattern = resolve::pattern(&r.url);
        let mut skip = |reason: String| {
            skips.push(Skip {
                pattern: pattern.clone(),
                reason,
            });
        };
        let Some(page) = &r.page else {
            skip("a redirect, with no page to see".into());
            continue;
        };
        if cx.test.skip.contains(&pattern) {
            skip("listed in `fespalier.test.skip`".into());
            continue;
        }
        let path = match samples::link_path(app, r, &cx.samples) {
            Ok(p) => p,
            Err(folder) => {
                skip(format!("no sample for {folder} in `{}`", cx.samples_key));
                continue;
            }
        };
        let guards = guards_above(app, r);
        if !guards.is_empty() && !overrides {
            skip(format!(
                "guarded by {}; give {} an `overrides(String pattern)` that gets past it",
                guards.join(", "),
                cx.setup_shown
            ));
            continue;
        }
        let is_function = page.class.chars().next().is_some_and(char::is_lowercase);
        if is_function && !cfg.semantics_ids {
            skip("a function page; set `semantics_ids: true` so its test can find it".into());
            continue;
        }
        // One argument to a line, each with a trailing comma, at every level: the short style of
        // `dart format` (an app whose SDK is older than 3.7) keeps such a call split whatever
        // its length, so it has nothing to change; the tall style is held off by
        // `// dart format off`, which the short one does not read.
        //
        // One thing is left to the formatter's width: a named argument whose value doesn't fit
        // moves to the next line, so `initialLocation:` does too, when it would pass 80 columns
        // (the one place a long string can sit after a name).
        let location = format!("        initialLocation: {},", dart_str(&path));
        let location = if location.chars().count() > 80 {
            format!("        initialLocation:\n            {},", dart_str(&path))
        } else {
            location
        };
        let mut line = format!(
            "  testWidgets(\n    {},\n    (tester) => smokeTestRoute(\n      tester,\n      {},\n      AppRoutes.router(\n{location}\n      ),\n",
            dart_str(&format!("{pattern} at {path}")),
            dart_str(&pattern),
        );
        if !cfg.semantics_ids {
            let file = rel(r, Kind::Page);
            let n = pages.iter().position(|p| *p == file).unwrap_or_else(|| {
                pages.push(file);
                pages.len() - 1
            });
            let _ = writeln!(
                line,
                "      page: find.byType(\n        _i{n}.{},\n      ),",
                page.class
            );
        }
        if overrides {
            let _ = writeln!(
                line,
                "      overrides: setup.overrides(\n        {},\n      ),",
                dart_str(&pattern)
            );
        }
        if cx.setup.as_ref().is_some_and(|s| s.app) {
            line.push_str("      app: setup.app,\n");
        }
        if cx.test.timeout != DEFAULT_TEST_TIMEOUT {
            let _ = writeln!(
                line,
                "      timeout: const Duration(milliseconds: {}),",
                cx.test.timeout
            );
        }
        line.push_str("    ),\n  );\n");
        tests.push((guards, line));
    }
    if tests.is_empty() && skips.is_empty() {
        bail!("no route has a page: there is nothing for a test to open");
    }

    let mut out = format!(
        "{MARKER} from {}/: don't edit it, run `fsp test` again.\n// dart format off\n// ignore_for_file: type=lint, unused_import\n//\n",
        cfg.app_dir
    );
    out.push_str(
        "// A widget smoke test per route: each opens the route at a sample URL with pumpRouter and\n// waits, on the test's fake clock, until its page is on screen. ",
    );
    out.push_str(&match &cx.setup {
        Some(s) if s.overrides && s.app => format!(
            "Provider overrides and the app\n// around the router come from {}.\n",
            s.path
        ),
        Some(s) if s.overrides => format!("Provider overrides come\n// from {}.\n", s.path),
        Some(s) => format!(
            "The app around the router\n// comes from {}; the tests boot without provider overrides.\n",
            s.path
        ),
        None => "No setup file: the tests boot\n// without provider overrides.\n".to_string(),
    });
    if !skips.is_empty() {
        out.push_str("//\n");
        for s in &skips {
            let _ = writeln!(out, "//   skipped {}: {}", s.pattern, s.reason);
        }
    }
    out.push('\n');
    out.push_str("import 'package:fespalier/testing.dart';\n");
    out.push_str("import 'package:flutter_test/flutter_test.dart';\n");
    let _ = writeln!(
        out,
        "import {};",
        dart_str(&format!("package:{}/{}", cx.package, in_lib(&cfg.output)))
    );
    for (i, file) in pages.iter().enumerate() {
        let uri = dart_str(&format!(
            "package:{}/{}/{file}",
            cx.package,
            in_lib(&cfg.app_dir)
        ));
        out.push_str(&import_as(&uri, &format!("_i{i}")));
    }
    if let Some(s) = &cx.setup {
        out.push('\n');
        out.push_str(&import_as(
            &dart_str(&setup_import(&cx.test.out, &s.path)),
            "setup",
        ));
    }
    out.push_str("\nvoid main() {\n");
    for (guards, line) in &tests {
        if !guards.is_empty() {
            let _ = writeln!(out, "  // Guarded by {}.", guards.join(", "));
        }
        out.push_str(line);
    }
    out.push_str("}\n");
    Ok((out, skips))
}

/// Which of `overrides` and `app` the setup file's source declares, each as a function of the
/// one argument it must take.
fn read_setup(path: &str, src: &str) -> Result<Setup> {
    let module = parse_cache::parse(src);
    let takes_one = |f: &Function| {
        f.params.iter().filter(|p| !p.named && p.required).count() == 1
            && !f.params.iter().any(|p| p.named && p.required)
    };
    let find = |name: &str| module.functions.iter().find(|f| f.name == name);
    let overrides = find("overrides");
    let app = find("app");
    if let Some(f) = overrides
        && !takes_one(f)
    {
        bail!(
            "{path}: `overrides` must be a function of the route's pattern: `List<Override> overrides(String pattern) => [...]`"
        );
    }
    if let Some(f) = app
        && !takes_one(f)
    {
        bail!(
            "{path}: `app` must be a function of the router: `Widget app(GoRouter router) => MaterialApp.router(routerConfig: router)`"
        );
    }
    if overrides.is_none() && app.is_none() {
        bail!(
            "{path} has neither `overrides` nor `app`: write `List<Override> overrides(String pattern) => [...]` (the providers each route's test boots with) or `Widget app(GoRouter router) => ...` (the app around the router)"
        );
    }
    Ok(Setup {
        path: path.to_string(),
        overrides: overrides.is_some(),
        app: app.is_some(),
    })
}

/// What `fsp test` would write: the file's text and where it goes, and what it skips.
#[derive(Debug)]
pub struct Built {
    pub text: String,
    /// The test file, relative to the project root: `test/routes/routes_test.dart`.
    pub shown: String,
    pub skips: Vec<Skip>,
    /// How many routes get a test.
    pub routes: usize,
}

/// Reads the config, the route tree and the setup file, checks them, and renders the test file.
/// Everything `fsp test` does before it touches the test file.
pub fn build(project: &Path) -> Result<Built> {
    let cfg = Config::load(project)?;
    let Some(package) = cfg.package.clone() else {
        bail!(
            "`fsp test` imports the app as a package (`package:<name>/...`): give pubspec.yaml a `name:`"
        );
    };
    let raw = cfg.test.clone().unwrap_or_default();
    let test = raw.validate()?;
    let setup_path = test.setup_path();
    let has_setup_file = project.join(&setup_path).is_file();
    if test.setup.is_some() && !has_setup_file {
        bail!("`fespalier.test.setup`: {setup_path} does not exist");
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
        bail!("{} error(s); no tests", diags.error_count());
    }
    check_skip_list(&app, &test.skip)?;

    // The samples: this section's, else the Maestro ones. Only that one key of `maestro:` is
    // read, so a `maestro:` section `fsp maestro` would refuse doesn't stop `fsp test`.
    let (samples_key, raw_samples) = match (
        raw.raw_samples(),
        cfg.maestro.as_ref().and_then(|m| m.raw_samples()),
    ) {
        (Some(s), _) => ("fespalier.test.samples", Some(s)),
        (None, Some(s)) => ("fespalier.maestro.samples", Some(s)),
        (None, None) => ("fespalier.test.samples", None),
    };
    let parsed = samples::parse(samples_key, raw_samples)?;
    let samples = samples::resolve(&app, &cfg, samples_key, &parsed)?;

    let setup = if has_setup_file {
        let src = fs::read_to_string(project.join(&setup_path))
            .with_context(|| format!("reading {setup_path}"))?;
        Some(read_setup(&setup_path, &src)?)
    } else {
        None
    };
    let cx = TestCx {
        package,
        test,
        setup,
        setup_shown: setup_path,
        samples_key: samples_key.to_string(),
        samples,
    };
    let (text, skips) = file(&app, &cfg, &cx)?;
    let routes = app.routes.iter().filter(|r| r.is_route()).count() - skips.len();
    Ok(Built {
        text,
        shown: format!("{}/{FILE}", cx.test.out),
        skips,
        routes,
    })
}

/// `fsp test` (write) and `fsp test --check` (compare, change nothing, fail when stale).
pub fn run(project: &Path, check: bool) -> Result<()> {
    let Built {
        text,
        shown,
        skips,
        routes,
    } = build(project)?;
    for s in &skips {
        eprintln!("  skipped {}: {}", s.pattern, s.reason);
    }

    let path = project.join(&shown);
    let disk = fs::read(&path).ok();
    if let Some(disk) = &disk
        && !String::from_utf8_lossy(disk).starts_with(MARKER)
    {
        bail!(
            "{shown} was not written by `fsp test` (its first line isn't ``// Written by `fsp test` ``); move it, or set `fespalier.test.out` to another folder"
        );
    }
    let count = plural(routes, "route");
    if check {
        match disk {
            None => bail!("{shown} is missing; run `fsp test`"),
            Some(d) if d != text.as_bytes() => bail!("{shown} is out of date; run `fsp test`"),
            Some(_) => {
                eprintln!("✓ test: {shown} is up to date ({count})");
                return Ok(());
            }
        }
    }
    let skipped = if skips.is_empty() {
        String::new()
    } else {
        format!("; {} skipped", plural(skips.len(), "route"))
    };
    if disk.as_deref() == Some(text.as_bytes()) {
        eprintln!("✓ test: {count} in {shown} (unchanged){skipped}");
        return Ok(());
    }
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    }
    fs::write(&path, &text).with_context(|| format!("writing {}", path.display()))?;
    eprintln!("  wrote {shown}");
    eprintln!("✓ test: {count} in {shown}{skipped}");
    Ok(())
}
