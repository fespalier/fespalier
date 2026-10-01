//! `fsp routes`: the route table on stdout, as text (the same rows as the
//! header of `app.g.dart`), as JSON lines for tools, or (`--graph`) as a Mermaid or Graphviz
//! graph of the route tree (see `graph.rs`).
//!
//! Text: `/products/:id  ProductRoute  products/$id/page.dart  (data, transition)`.
//!
//! JSON, one object per route (the same data as `AppManifest` in the generated
//! Dart, plus the file names):
//!
//! ```text
//! {"pattern","route","file","tags":[…],"params":[{"name","type","in"}],
//!  "folder","presentation","groups":[…],"layouts":[…],
//!  "tabs":[{"layout","index","branch"}],"data_keys":[…]|null,"meta":"…"|null,
//!  "catch_all":{"name","optional"}|null,"remount":"on_segments","paths":{"fr":"/produits/:id"}}
//! ```
//!
//! `file` and `meta` are relative to the project root (`meta` is the route's
//! meta.dart, or null); `folder`, `layouts` and `tabs[].layout` are relative to
//! the app folder, with `""` for the app folder itself. `in` is `path` or
//! `query`; `type` is the Dart type by name (`int?`, `List<Category>`: an enum without the
//! import prefix its file gave it); `remount` (since 0.6.0) is when the route's page gets a fresh state
//! because its URL changed, `on_segments` or `on_location` (its folder's `route.dart`, else the pubspec's), and is only there
//! for a route that has one; `paths` is the route's path in each locale its folders spell it in, and only there for a route with a localized segment; `presentation` is `page`, `redirect`, `root` (on the root navigator, from a
//! `navigator.dart`) or `custom` (a `present.dart` builds its page).

use std::path::Path;

use anyhow::{Result, bail};
use serde_json::json;

use crate::config::{Config, Remount};
use crate::emit;
use crate::graph;
use crate::manifest;
use crate::resolve::{App, Route};
use crate::{analyze, diag};

pub fn run(project: &Path, json: bool, graph: Option<graph::Format>) -> Result<()> {
    let cfg = Config::load(project)?;
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
        bail!("{} error(s); no route table", diags.error_count());
    }
    if let Some(format) = graph {
        print!("{}", graph::render(&app, format));
        return Ok(());
    }
    let out = if json {
        json_lines(&app, &cfg.app_dir)
    } else {
        table(&app)
    };
    for line in out {
        println!("{line}");
    }
    Ok(())
}

/// The routes (pages and redirects), in the order the generated file lists them.
fn pages(app: &App) -> impl Iterator<Item = &Route> {
    app.routes.iter().filter(|r| r.is_route())
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
            let mut row = json!({
                "pattern": i.path,
                "route": i.class,
                "file": format!("{app_dir}/{}", i.file),
                "tags": emit::tags(r),
                "params": path.chain(query).collect::<Vec<_>>(),
                "folder": i.folder,
                "presentation": i.presentation.unwrap_or("page"),
                "groups": i.groups,
                "layouts": i.layouts,
                "tabs": tabs,
                "data_keys": i.data_keys,
                "meta": i.meta.map(|m| format!("{app_dir}/{m}")),
                "catch_all": i.catch_all.map(|(name, optional)| json!({"name": name, "optional": optional})),
            });
            // Only for a route that remounts, so the rows of an app without any are as they were.
            if r.remount != Remount::Never {
                row["remount"] = r.remount.config_name().into();
            }
            // Only for a route with a localized segment, so the rows of an app without any are as they were.
            if !i.paths.is_empty() {
                row["paths"] = i.paths.iter().map(|(l, p)| (l.clone(), json!(p))).collect::<serde_json::Map<_, _>>().into();
            }
            row.to_string()
        })
        .collect()
}
