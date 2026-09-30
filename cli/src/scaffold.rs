//! `fsp new products/[id] --data --loading --error`

use std::collections::HashMap;
use std::fs;
use std::path::Path;

use anyhow::{bail, Result};
use clap::Args;
use serde::Serialize;

use crate::diag::Diags;
use crate::resolve::{self, pascal};
use crate::scan::{self, parse_segment, Seg};
use crate::templates;

#[derive(Args)]
pub struct NewArgs {
    /// Route path under lib/app. `[id]` and `:id` are accepted for `$id`
    /// so you don't have to quote `$` in the shell.
    pub route: String,
    /// Class name stem (default: from the path, e.g. `ProductsId`)
    #[arg(long)]
    pub name: Option<String>,
    #[arg(long)]
    pub data: bool,
    #[arg(long)]
    pub loading: bool,
    #[arg(long)]
    pub error: bool,
    #[arg(long)]
    pub layout: bool,
    #[arg(long)]
    pub guard: bool,
}

#[derive(Serialize)]
struct Cx {
    stem: String,
    segs: Vec<SegCx>,
    data: bool,
    /// ` $orderId $itemId`, appended to the page's placeholder text.
    label: String,
    /// `/orders/$orderId`, interpolated in data.dart's placeholder.
    path: String,
}

#[derive(Serialize)]
struct SegCx {
    name: String,
    ty: String,
}

pub fn new_route(project: &Path, a: &NewArgs) -> Result<()> {
    let app_dir = project.join("lib/app");
    let parts: Vec<String> = a
        .route
        .trim_matches('/')
        .split('/')
        .filter(|s| !s.is_empty())
        .map(|p| match p.strip_prefix('[').and_then(|p| p.strip_suffix(']')).or_else(|| p.strip_prefix(':')) {
            Some(n) => format!("${n}"),
            None => p.to_string(),
        })
        .collect();
    let segs: Vec<Seg> = parts.iter().map(|p| parse_segment(p).map_err(anyhow::Error::msg)).collect::<Result<_>>()?;
    let rel = parts.join("/");

    // Segments that already exist keep the type the tree gives them.
    let mut diags = Diags::default();
    let app = resolve::resolve(&scan::scan(&app_dir, &mut diags)?, &mut diags);
    let known: HashMap<&str, &str> = app
        .routes
        .iter()
        .enumerate()
        .filter(|(_, r)| matches!(r.seg, Some(Seg::Dynamic(_))))
        .map(|(id, r)| (r.dir.as_str(), app.seg_type(id)))
        .collect();
    let mut seg_cx = vec![];
    for (i, s) in segs.iter().enumerate() {
        if let Seg::Dynamic(name) = s {
            let dir = parts[..=i].join("/");
            let ty = known.get(dir.as_str()).copied().unwrap_or("String").to_string();
            seg_cx.push(SegCx { name: name.clone(), ty });
        }
    }

    let stem = a.name.clone().unwrap_or_else(|| {
        let p = pascal(&rel);
        if p.is_empty() { "Home".into() } else { p }
    });
    let cx = Cx {
        label: seg_cx.iter().map(|s| format!(" ${}", s.name)).collect(),
        path: format!("/{rel}"),
        stem,
        segs: seg_cx,
        data: a.data,
    };

    let wanted = [
        ("page", true),
        ("data", a.data),
        ("loading", a.loading),
        ("error", a.error),
        ("layout", a.layout),
        ("guard", a.guard),
    ];
    let dir = app_dir.join(&rel);
    fs::create_dir_all(&dir)?;
    let mut wrote = 0;
    for (kind, on) in wanted {
        if !on {
            continue;
        }
        let path = dir.join(format!("{kind}.dart"));
        let shown = format!("lib/app/{}{kind}.dart", if rel.is_empty() { String::new() } else { format!("{rel}/") });
        if path.exists() {
            eprintln!("  skip  {shown} (exists)");
            continue;
        }
        fs::write(&path, templates::render(&format!("new/{kind}.dart"), &cx))?;
        eprintln!("  new   {shown}");
        wrote += 1;
    }
    if wrote == 0 {
        bail!("nothing to create");
    }
    Ok(())
}
