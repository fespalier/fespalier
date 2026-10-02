//! `fsp new products/[id] --data --action --loading --error`

use std::collections::HashMap;
use std::fs;
use std::path::Path;

use anyhow::{Result, bail};
use clap::Args;
use serde::Serialize;

use crate::config::Config;
use crate::diag::Diags;
use crate::resolve::{self, pascal};
use crate::scan::{self, FileStyle, Seg, parse_segment};
use crate::templates;

#[derive(Args)]
pub struct NewArgs {
    /// Route path under the app folder (lib/app). `[id]` and `:id` are accepted for `$id`,
    /// `[...rest]` for the catch-all `$$rest` and `[[...rest]]` for `$$$rest`, so you don't
    /// have to quote `$` in the shell.
    pub route: String,
    /// Class name stem (default: from the path, e.g. `ProductsId`); with --function,
    /// the typed route's name, written as `const routeName = '...';`
    #[arg(long)]
    pub name: Option<String>,
    /// Write the views as top-level functions (`Widget page(...)`) rather than widget classes
    #[arg(long)]
    pub function: bool,
    #[arg(long)]
    pub data: bool,
    /// Write action.dart: a typed write beside the page (or a section's layout)
    #[arg(long)]
    pub action: bool,
    #[arg(long)]
    pub loading: bool,
    #[arg(long)]
    pub error: bool,
    #[arg(long)]
    pub layout: bool,
    #[arg(long)]
    pub not_found: bool,
    #[arg(long)]
    pub guard: bool,
    #[arg(long)]
    pub transition: bool,
}

/// What `fsp new` parses: the route flags plus `--no-page`.
#[derive(Args)]
pub struct NewCmd {
    #[command(flatten)]
    pub args: NewArgs,
    /// Don't write page.dart (implied for a `(group)` folder, which can't have one)
    #[arg(long)]
    pub no_page: bool,
}

#[derive(Serialize)]
struct Cx {
    stem: String,
    /// The views are top-level functions.
    function: bool,
    /// `--name` with `--function`: the `routeName` to write.
    name: Option<String>,
    segs: Vec<SegCx>,
    data: bool,
    /// The named parameters of action.dart's function: the segments, then `input`.
    action_params: Vec<String>,
    /// ` $orderId $itemId`, appended to the page's placeholder text.
    label: String,
    /// `/orders/$orderId`, interpolated in data.dart's placeholder.
    path: String,
}

#[derive(Serialize)]
struct SegCx {
    name: String,
    ty: String,
    /// `required int id`: a named parameter of a function view.
    param: String,
    /// `required String id`: the same for a not-found view, which gets the raw segment.
    string_param: String,
    /// `required this.id`: a named parameter of a widget constructor.
    field: String,
}

impl SegCx {
    fn new(name: String, ty: String) -> Self {
        Self {
            param: format!("required {ty} {name}"),
            string_param: format!("required String {name}"),
            field: format!("required this.{name}"),
            name,
            ty,
        }
    }
}

/// Scaffolds the route, writing a page.dart unless the folder is a `(group)`.
#[cfg(test)]
/// Returns the files it created, as `lib/app/...` paths.
pub fn new_route(project: &Path, a: &NewArgs) -> Result<Vec<String>> {
    new_route_opts(project, a, false)
}

pub fn new_route_opts(project: &Path, a: &NewArgs, no_page: bool) -> Result<Vec<String>> {
    let cfg = Config::load(project)?;
    let app_dir = project.join(&cfg.app_dir);
    let parts: Vec<String> = a
        .route
        .trim_matches('/')
        .split('/')
        .filter(|s| !s.is_empty())
        .map(|p| {
            let bracketed = |p: &str| {
                p.strip_prefix('[')
                    .and_then(|p| p.strip_suffix(']'))
                    .map(str::to_string)
            };
            // `[[...rest]]` → `$$$rest`, `[...rest]` → `$$rest`, `[id]` → `$id`.
            if let Some(n) = bracketed(p)
                .and_then(|i| bracketed(&i))
                .and_then(|i| i.strip_prefix("...").map(str::to_string))
            {
                return format!("$$${n}");
            }
            match bracketed(p) {
                Some(n) => match n.strip_prefix("...") {
                    Some(rest) => format!("$${rest}"),
                    None => format!("${n}"),
                },
                None => match p.strip_prefix(':') {
                    Some(n) => format!("${n}"),
                    None => p.to_string(),
                },
            }
        })
        .collect();
    let segs: Vec<Seg> = parts
        .iter()
        .map(|p| parse_segment(p).map_err(anyhow::Error::msg))
        .collect::<Result<_>>()?;
    let rel = parts.join("/");

    // Segments that already exist keep the type the tree gives them.
    let mut diags = Diags::default();
    let libs = crate::enums::Libs::for_app(&app_dir, &cfg);
    let app = resolve::resolve(
        &scan::scan(&app_dir, &mut diags)?,
        true,
        crate::config::Remount::Never,
        false,
        &libs,
        &mut diags,
    );
    let known: HashMap<&str, String> = app
        .routes
        .iter()
        .enumerate()
        .filter(|(_, r)| matches!(r.seg, Some(Seg::Dynamic(_) | Seg::CatchAll(..))))
        .map(|(id, r)| (r.dir.as_str(), app.display_type(app.seg_type(id))))
        .collect();
    let mut seg_cx = vec![];
    for (i, s) in segs.iter().enumerate() {
        match s {
            Seg::Dynamic(name) => {
                let dir = parts[..=i].join("/");
                let ty = known
                    .get(dir.as_str())
                    .cloned()
                    .unwrap_or_else(|| "String".to_string());
                seg_cx.push(SegCx::new(name.clone(), ty));
            }
            Seg::CatchAll(name, _) => {
                let dir = parts[..=i].join("/");
                let ty = known
                    .get(dir.as_str())
                    .cloned()
                    .unwrap_or_else(|| "List<String>".to_string());
                seg_cx.push(SegCx::new(name.clone(), ty));
            }
            _ => {}
        }
    }

    if let (true, Some(n)) = (a.function, &a.name)
        && !resolve::valid_route_name(n)
    {
        bail!(
            "--name `{n}` names the route class `{n}Route`, so it must be UpperCamelCase (letters, digits, `_`), e.g. `KycShopName`"
        );
    }
    let stem = a.name.clone().unwrap_or_else(|| {
        let p = pascal(&rel);
        if p.is_empty() { "Home".into() } else { p }
    });
    let cx = Cx {
        function: a.function,
        name: a.name.clone().filter(|_| a.function),
        label: seg_cx.iter().map(|s| format!(" ${}", s.name)).collect(),
        path: format!("/{rel}"),
        stem,
        action_params: seg_cx
            .iter()
            .map(|s| s.param.clone())
            .chain(["required Object? input".to_string()])
            .collect(),
        segs: seg_cx,
        data: a.data,
    };

    // A group has no URL of its own, so it can't serve a page (and one would
    // collide with the page of the folder above it).
    let is_group = matches!(segs.last(), Some(Seg::Group(_)));
    if a.not_found && matches!(segs.last(), Some(Seg::CatchAll(..))) {
        bail!(
            "a catch-all folder can't have a not_found.dart: it matches every URL below it, so none is unknown"
        );
    }
    let wanted = [
        ("page", !no_page && !is_group),
        ("data", a.data),
        ("action", a.action),
        ("loading", a.loading),
        ("error", a.error),
        ("layout", a.layout),
        ("not_found", a.not_found),
        ("guard", a.guard),
        ("transition", a.transition),
    ];
    if !wanted.iter().any(|(_, on)| *on) {
        let why = if is_group {
            "a (group) folder has no page"
        } else {
            "--no-page skips the page"
        };
        bail!(
            "nothing to create: {why}; also pass --action, --layout, --loading, --error, --not-found, --guard or --transition"
        );
    }
    let dir = app_dir.join(&rel);
    fs::create_dir_all(&dir)?;
    let mut created = vec![];
    for (kind, on) in wanted {
        if !on {
            continue;
        }
        // `file_style` picks how a multi-word kind is spelled; the other spelling counts as there.
        let (snake, kebab) = (
            format!("{kind}.dart"),
            format!("{}.dart", kind.replace('_', "-")),
        );
        let file = if cfg.file_style == FileStyle::Kebab {
            &kebab
        } else {
            &snake
        };
        let at = |f: &str| {
            format!(
                "{}/{}{f}",
                cfg.app_dir,
                if rel.is_empty() {
                    String::new()
                } else {
                    format!("{rel}/")
                }
            )
        };
        let path = dir.join(file);
        let shown = at(file);
        if let Some(present) = [&snake, &kebab].into_iter().find(|f| dir.join(f).exists()) {
            eprintln!("  skip  {} (exists)", at(present));
            continue;
        }
        fs::write(&path, templates::render(&format!("new/{kind}.dart"), &cx))?;
        eprintln!("  new   {shown}");
        created.push(shown);
    }
    if created.is_empty() {
        bail!("nothing to create");
    }
    Ok(created)
}
