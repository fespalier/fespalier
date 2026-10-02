//! `fsp maestro`: one Maestro smoke flow per route, written from the route tree.
//!
//! Maestro drives an app from the outside, through the platform's accessibility tree, so it
//! cannot see a Flutter `Key`. It sees a `Semantics(identifier:)`, which is what the
//! `semantics_ids` config key gives every page (`route:/products/:id`, see
//! [`resolve::semantics_id`]). A flow here opens a sample URL of the route (`openLink`) and waits
//! until that identifier is on the screen: the route exists, its guards let the flow through,
//! its data loaded and its page was built.
//!
//! Everything is a function of the tree and the pubspec: stable order, no dates, so `--check`
//! can compare the files on disk byte for byte. Like `fsp links`, this reads its own config
//! section and checks it only when the command runs, so a mistake in it never stops `fsp gen`.
//!
//! A route gets a flow unless it cannot be opened by one: a redirect (there is no page to
//! see), a route `fsp links` does not open (`const linkable = false;`, for an app target), a
//! route with a dynamic segment that has no sample, or a guarded route when there is no
//! `guard_flow` to get past the guard. Each skip is printed, and none fails `--check`.
//!
//! The files `fsp maestro` writes start with [`MARKER`]. It removes the ones it wrote that no
//! route needs any more, and never reads or touches any other file in the folder, so
//! hand-written flows live beside the generated ones.

use std::collections::HashMap;
use std::fs;
use std::path::Path;

use anyhow::{Context, Result, bail};

use crate::config::{Config, Maestro, SampleValue, Target, parent, relative_dir};
use crate::emit::rel;
use crate::links::url_segment;
use crate::resolve::{self, App, Route};
use crate::scan::{Kind, Seg};
use crate::{analyze, diag, plural};

/// What the first line of every file `fsp maestro` writes starts with: how it tells its own
/// files from yours.
const MARKER: &str = "# Written by `fsp maestro`";

/// One flow to write: its file name in the `out` folder, and its text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Flow {
    pub file: String,
    pub text: String,
}

/// A route that gets no flow, and why.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Skip {
    /// `/products/:id`.
    pub pattern: String,
    pub reason: String,
}

/// `ProductRoute` is `product_route`: an underscore before an upper-case letter that follows a
/// lower-case letter or a digit, then lower-case. The `_route` ending keeps a file from ever
/// being the workspace's `config.yaml`.
fn snake(name: &str) -> String {
    let mut out = String::new();
    let mut prev: Option<char> = None;
    for c in name.chars() {
        if c.is_uppercase() && prev.is_some_and(|p| p.is_lowercase() || p.is_ascii_digit()) {
            out.push('_');
        }
        out.extend(c.to_lowercase());
        prev = Some(c);
    }
    out
}

/// A YAML double-quoted scalar: a JSON string is one, and it keeps `#`, `:` and `${}` safe.
fn yaml_str(s: &str) -> String {
    // A string always serializes.
    serde_json::to_string(s).unwrap_or_default()
}

/// The parts of a sample, for each dynamic folder (an index into `app.routes`) that has one,
/// after checking each against the folder it is for.
fn resolve_samples(app: &App, cfg: &Config, m: &Maestro) -> Result<HashMap<usize, Vec<String>>> {
    let mut out = HashMap::new();
    for (key, value) in &m.samples {
        let Some(folder) = app.routes.iter().position(|f| f.dir == *key) else {
            bail!(
                "`fespalier.maestro.samples`: `{key}` is not a folder of {}; write it as `fsp routes` prints it, without `/page.dart` (`products/$id`)",
                cfg.app_dir
            );
        };
        let optional = match &app.routes[folder].seg {
            Some(Seg::Dynamic(_)) => None,
            Some(Seg::CatchAll(_, optional)) => Some(*optional),
            _ => bail!(
                "`fespalier.maestro.samples`: `{key}` is not a `$segment` folder; samples give the values of dynamic segments"
            ),
        };
        let parts: Vec<String> = match (value, optional) {
            (SampleValue::One(s), _) => vec![s.clone()],
            (SampleValue::Many(_), None) => bail!(
                "`fespalier.maestro.samples`: `{key}` is one segment; give one value, not a list"
            ),
            (SampleValue::Many(parts), Some(_)) => parts.clone(),
        };
        if parts.is_empty() && optional == Some(false) {
            bail!(
                "`fespalier.maestro.samples`: `{key}` is a catch-all that needs at least one part"
            );
        }
        let ty = app.seg_type(folder);
        let element = ty
            .strip_prefix("List<")
            .and_then(|t| t.strip_suffix('>'))
            .unwrap_or(ty);
        for part in &parts {
            if part.is_empty() {
                bail!("`fespalier.maestro.samples`: `{key}` is empty; a segment can't be");
            }
            let fits = match element {
                "int" => part.parse::<i64>().is_ok(),
                "double" | "num" => part.parse::<f64>().is_ok_and(f64::is_finite),
                "bool" => matches!(part.as_str(), "true" | "false"),
                _ => true,
            };
            if !fits {
                bail!(
                    "`fespalier.maestro.samples`: `{key}` is a `{}` segment, and `{part}` is not one",
                    app.display_type(ty)
                );
            }
        }
        out.insert(folder, parts);
    }
    Ok(out)
}

/// The path of the route's URL with the samples filled in, percent-encoded: `/products/1`,
/// `/docs/guides/intro`. `Err` is the folder that has no sample. An optional catch-all with
/// none is left off.
fn link_path(
    app: &App,
    r: &Route,
    samples: &HashMap<usize, Vec<String>>,
) -> std::result::Result<String, String> {
    let mut out = String::new();
    let mut dynamic = r.segs.iter();
    for seg in &r.url {
        match seg {
            Seg::Static(s) => {
                out.push('/');
                out.push_str(&url_segment(s));
            }
            Seg::Dynamic(_) | Seg::CatchAll(..) => {
                let folder = dynamic.next().map_or(0, |(_, f)| *f);
                match (samples.get(&folder), seg) {
                    (Some(parts), _) => {
                        for p in parts {
                            out.push('/');
                            out.push_str(&url_segment(p));
                        }
                    }
                    (None, Seg::CatchAll(_, true)) => {}
                    (None, _) => return Err(app.routes[folder].dir.clone()),
                }
            }
            Seg::Group(_) => {}
        }
    }
    Ok(if out.is_empty() { "/".into() } else { out })
}

/// The `guard.dart` files at or above the route's folder, outermost first, relative to the
/// app folder. A `(group)` folder's guard covers what is in it, because a folder's path
/// includes its groups.
fn guards_above(app: &App, r: &Route) -> Vec<String> {
    let mut guards: Vec<&Route> = app
        .routes
        .iter()
        .filter(|g| {
            g.guard.is_some()
                && (g.dir.is_empty() || r.dir == g.dir || r.dir.starts_with(&format!("{}/", g.dir)))
        })
        .collect();
    guards.sort_by_key(|g| g.dir.split('/').filter(|p| !p.is_empty()).count());
    guards.into_iter().map(|g| rel(g, Kind::Guard)).collect()
}

/// The text of one route's flow.
fn flow_text(cfg: &Config, m: &Maestro, r: &Route, path: &str, guards: &[String]) -> String {
    let pattern = resolve::pattern(&r.url);
    let id = resolve::semantics_id(&r.url);
    let mut out = format!(
        "{MARKER} from {}/{}: don't edit it, run `fsp maestro` again.\n",
        cfg.app_dir,
        rel(r, Kind::Page)
    );
    let run_flow = m
        .guard_flow
        .as_deref()
        .filter(|_| !guards.is_empty())
        .map(|f| {
            let dir = relative_dir(&m.out, parent(f));
            let name = f.rsplit('/').next().unwrap_or(f);
            if dir.is_empty() {
                name.to_string()
            } else {
                format!("{dir}/{name}")
            }
        });
    if let Some(run) = &run_flow {
        out.push_str(&format!(
            "# Guarded by {}: {run} runs before the link.\n",
            guards.join(", ")
        ));
    }
    match &m.target {
        Target::App(id) => out.push_str(&format!("appId: {}\n", yaml_str(id))),
        Target::Web(url) => out.push_str(&format!("url: {}\n", yaml_str(url))),
    }
    out.push_str(&format!(
        "name: {}\ntags:\n  - \"fespalier\"\n---\n- launchApp\n",
        yaml_str(&pattern)
    ));
    if let Some(run) = &run_flow {
        out.push_str(&format!("- runFlow: {}\n", yaml_str(run)));
    }
    let link = yaml_str(&format!("{}{path}", m.link));
    if m.https_app_link {
        out.push_str(&format!(
            "- openLink:\n    link: {link}\n    autoVerify: true\n"
        ));
    } else {
        out.push_str(&format!("- openLink: {link}\n"));
    }
    out.push_str(&format!(
        "- extendedWaitUntil:\n    visible:\n      id: {}\n    timeout: {}\n",
        yaml_str(&id),
        m.timeout
    ));
    out
}

/// The flows for `app`, and the routes that get none, both in the order of the route table.
/// Nothing here touches the file system.
pub fn flows(app: &App, cfg: &Config, m: &Maestro) -> Result<(Vec<Flow>, Vec<Skip>)> {
    let samples = resolve_samples(app, cfg, m)?;
    let for_app = matches!(m.target, Target::App(_));
    let (mut flows, mut skips): (Vec<Flow>, Vec<Skip>) = (vec![], vec![]);
    let mut owners: HashMap<String, String> = HashMap::new();
    for r in app.routes.iter().filter(|r| r.is_route()) {
        let pattern = resolve::pattern(&r.url);
        let mut skip = |reason: String| {
            skips.push(Skip {
                pattern: pattern.clone(),
                reason,
            });
        };
        if r.page.is_none() {
            skip("a redirect, with no page to see".into());
            continue;
        }
        if for_app && !r.linkable {
            skip("`const linkable = false;`, so `fsp links` does not open the app at it".into());
            continue;
        }
        let path = match link_path(app, r, &samples) {
            Ok(p) => p,
            Err(folder) => {
                skip(format!(
                    "no sample for {folder} in `fespalier.maestro.samples`"
                ));
                continue;
            }
        };
        let guards = guards_above(app, r);
        if !guards.is_empty() && m.guard_flow.is_none() {
            skip(format!(
                "guarded by {}; set `fespalier.maestro.guard_flow` to a flow that gets past it",
                guards.join(", ")
            ));
            continue;
        }
        let file = format!("{}_route.yaml", snake(r.name.as_deref().unwrap_or("")));
        if let Some(other) = owners.insert(file.clone(), pattern.clone()) {
            let out = if m.out.is_empty() { "." } else { &m.out };
            bail!("two routes would write {out}/{file}: {other} and {pattern}");
        }
        flows.push(Flow {
            file,
            text: flow_text(cfg, m, r, &path, &guards),
        });
    }
    if flows.is_empty() && skips.is_empty() {
        bail!("no route has a page: there is nothing for a flow to open");
    }
    Ok((flows, skips))
}

/// The `*.yaml` files in `dir` that `fsp maestro` wrote (they start with [`MARKER`]), by name.
/// A file with another first line is somebody else's, and never read further.
fn owned_files(dir: &Path) -> Vec<String> {
    let Ok(entries) = fs::read_dir(dir) else {
        return vec![];
    };
    let mut names: Vec<String> = entries
        .filter_map(Result::ok)
        .filter(|e| e.path().is_file())
        .filter_map(|e| e.file_name().into_string().ok())
        .filter(|n| n.ends_with(".yaml"))
        .filter(|n| {
            fs::read_to_string(dir.join(n))
                .is_ok_and(|text| text.lines().next().is_some_and(|l| l.starts_with(MARKER)))
        })
        .collect();
    names.sort();
    names
}

/// `fsp maestro` (write) and `fsp maestro --check` (compare, change nothing, fail when stale).
pub fn run(project: &Path, check: bool) -> Result<()> {
    let cfg = Config::load(project)?;
    let Some(raw) = &cfg.maestro else {
        bail!(
            "no `maestro:` in the `fespalier:` section of pubspec.yaml; say what the flows open, e.g.\n  fespalier:\n    semantics_ids: true\n    maestro:\n      app_id: com.example.shop"
        );
    };
    if !cfg.semantics_ids {
        bail!(
            "`fsp maestro` finds each page by its semantics identifier: set `semantics_ids: true` in the `fespalier:` section of pubspec.yaml, then run `fsp gen`"
        );
    }
    let m = raw.validate(cfg.links.as_ref())?;
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
        bail!("{} error(s); no flows", diags.error_count());
    }
    if let Some(guard) = &m.guard_flow
        && !project.join(guard).is_file()
    {
        bail!("`fespalier.maestro.guard_flow`: {guard} does not exist");
    }
    let (flows, skips) = flows(&app, &cfg, &m)?;
    for s in &skips {
        eprintln!("  skipped {}: {}", s.pattern, s.reason);
    }

    let out = &m.out;
    let shown = |file: &str| {
        if out.is_empty() {
            file.to_string()
        } else {
            format!("{out}/{file}")
        }
    };
    let folder = if out.is_empty() { "." } else { out.as_str() };
    let (mut written, mut stale) = (0, vec![]);
    for f in &flows {
        let path = project.join(shown(&f.file));
        match fs::read(&path) {
            Ok(disk) if disk == f.text.as_bytes() => continue,
            Ok(_) => stale.push(format!("{} is out of date", shown(&f.file))),
            Err(_) => stale.push(format!("{} is missing", shown(&f.file))),
        }
        if check {
            continue;
        }
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
        }
        fs::write(&path, &f.text).with_context(|| format!("writing {}", path.display()))?;
        eprintln!("  wrote {}", shown(&f.file));
        written += 1;
    }
    for name in owned_files(&project.join(out)) {
        if flows.iter().any(|f| f.file == name) {
            continue;
        }
        stale.push(format!("{} is no longer a route's flow", shown(&name)));
        if !check {
            let path = project.join(shown(&name));
            fs::remove_file(&path).with_context(|| format!("removing {}", path.display()))?;
            eprintln!("  removed {}", shown(&name));
        }
    }

    let count = flows.len();
    if check {
        if stale.is_empty() {
            eprintln!(
                "✓ maestro: {} in {folder} are up to date",
                plural(count, "flow")
            );
            return Ok(());
        }
        for s in &stale {
            eprintln!("{s}");
        }
        bail!("{} flow(s) out of date; run `fsp maestro`", stale.len());
    }
    let skipped = if skips.is_empty() {
        String::new()
    } else {
        format!("; {} skipped", plural(skips.len(), "route"))
    };
    eprintln!(
        "✓ maestro: {} in {folder} ({written} written, {} unchanged){skipped}",
        plural(count, "flow"),
        count - written
    );
    Ok(())
}
