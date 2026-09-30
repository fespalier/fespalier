//! `fsp routes`: the route table on stdout, as text (the same rows as the
//! header of `app.g.dart`) or as JSON lines for tools.
//!
//! Text: `/products/:id  ProductRoute  products/$id/page.dart  (data, transition)`.
//!
//! JSON, one object per route:
//! `{"pattern","route","file","tags":[…],"params":[{"name","type","in"}]}`
//! where `file` is relative to the project root and `in` is `path` or `query`.

use std::path::Path;

use anyhow::{bail, Result};
use serde_json::json;

use crate::config::Config;
use crate::resolve::{self, App, Route};
use crate::{analyze, diag};

pub fn run(project: &Path, json: bool) -> Result<()> {
    let cfg = Config::load(project)?;
    let app_dir = project.join(&cfg.app_dir);
    if !app_dir.is_dir() {
        bail!("{} not found (set `fespalier: app_dir:` in pubspec.yaml, or run `fsp init`)", app_dir.display());
    }
    let (_, diags, app) = analyze(&app_dir, &cfg)?;
    diag::render(&app_dir, &cfg.app_dir, &diags);
    if diags.has_errors() {
        bail!("{} error(s); no route table", diags.error_count());
    }
    let out = if json { json_lines(&app, &cfg.app_dir) } else { table(&app) };
    for line in out {
        println!("{line}");
    }
    Ok(())
}

/// The routes that serve a page, in the order the generated file lists them.
fn pages(app: &App) -> impl Iterator<Item = &Route> {
    app.routes.iter().filter(|r| r.page.is_some())
}

fn class(r: &Route) -> String {
    format!("{}Route", r.name.as_deref().unwrap_or("?"))
}

fn file(r: &Route) -> String {
    if r.dir.is_empty() { "page.dart".into() } else { format!("{}/page.dart", r.dir) }
}

/// What the route has besides its page; the same tags as the header of `app.g.dart`.
fn tags(r: &Route) -> Vec<&'static str> {
    let mut tags = vec![];
    if r.data.is_some() {
        tags.push("data");
    }
    if r.guard.is_some() {
        tags.push("guard");
    }
    if r.layout.is_some() {
        tags.push("layout");
    }
    if r.transition.is_some() {
        tags.push("transition");
    }
    tags
}

pub fn table(app: &App) -> Vec<String> {
    let rows: Vec<(String, String, String)> = pages(app)
        .map(|r| {
            let tags = tags(r);
            let tags = if tags.is_empty() { String::new() } else { format!("  ({})", tags.join(", ")) };
            (resolve::pattern(&r.url), class(r), format!("{}{tags}", file(r)))
        })
        .collect();
    let w0 = rows.iter().map(|r| r.0.len()).max().unwrap_or(0);
    let w1 = rows.iter().map(|r| r.1.len()).max().unwrap_or(0);
    rows.into_iter().map(|(p, n, f)| format!("{p:w0$}  {n:w1$}  {f}")).collect()
}

pub fn json_lines(app: &App, app_dir: &str) -> Vec<String> {
    pages(app)
        .map(|r| {
            let path = app.typed_segs(r).into_iter().map(|(n, t)| json!({"name": n, "type": t, "in": "path"}));
            let query = r.query.iter().map(|(n, t)| json!({"name": n, "type": t, "in": "query"}));
            json!({
                "pattern": resolve::pattern(&r.url),
                "route": class(r),
                "file": format!("{app_dir}/{}", file(r)),
                "tags": tags(r),
                "params": path.chain(query).collect::<Vec<_>>(),
            })
            .to_string()
        })
        .collect()
}
