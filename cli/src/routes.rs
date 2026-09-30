//! `fsp routes`: the route table on stdout, as text (the same rows as the
//! header of `app.g.dart`) or as JSON lines for tools.
//!
//! Text: `/products/:id  ProductRoute  products/$id/page.dart  (data, transition)`.
//!
//! JSON, one object per route (the same data as `AppManifest` in the generated
//! Dart, plus the file names):
//!
//! ```text
//! {"pattern","route","file","tags":[…],"params":[{"name","type","in"}],
//!  "folder","presentation","groups":[…],"layouts":[…],
//!  "tabs":[{"layout","index","branch"}],"data_keys":[…]|null,"meta":"…"|null}
//! ```
//!
//! `file` and `meta` are relative to the project root (`meta` is the route's
//! meta.dart, or null); `folder`, `layouts` and `tabs[].layout` are relative to
//! the app folder, with `""` for the app folder itself. `in` is `path` or
//! `query`; `presentation` is `page` or `redirect`.

use std::path::Path;

use anyhow::{bail, Result};
use serde_json::json;

use crate::config::Config;
use crate::emit;
use crate::manifest;
use crate::resolve::{App, Route};
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

/// The routes (pages and redirects), in the order the generated file lists them.
fn pages(app: &App) -> impl Iterator<Item = &Route> {
    app.routes.iter().filter(|r| r.is_route())
}

/// What the route has besides its page; the same tags as the header of `app.g.dart`.
fn tags(r: &Route) -> Vec<&'static str> {
    let mut tags = vec![];
    if r.redirect.is_some() {
        tags.push("redirect");
    }
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
    emit::table(app)
}

pub fn json_lines(app: &App, app_dir: &str) -> Vec<String> {
    let infos = manifest::collect(app);
    pages(app)
        .zip(infos)
        .map(|(r, i)| {
            let path = i.segments.iter().map(|(n, t)| json!({"name": n, "type": t, "in": "path"}));
            let query = i.query.iter().map(|(n, t)| json!({"name": n, "type": t, "in": "query"}));
            let tabs: Vec<_> =
                i.tabs.iter().map(|t| json!({"layout": t.layout, "index": t.index, "branch": t.branch})).collect();
            json!({
                "pattern": i.path,
                "route": i.class,
                "file": format!("{app_dir}/{}", i.file),
                "tags": tags(r),
                "params": path.chain(query).collect::<Vec<_>>(),
                "folder": i.folder,
                "presentation": if i.redirect { "redirect" } else { "page" },
                "groups": i.groups,
                "layouts": i.layouts,
                "tabs": tabs,
                "data_keys": i.data_keys,
                "meta": i.meta.map(|m| format!("{app_dir}/{m}")),
            })
            .to_string()
        })
        .collect()
}
