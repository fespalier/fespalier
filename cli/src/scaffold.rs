//! `trellis new products/[id] --data --loading --error`

use std::fs;
use std::path::Path;

use anyhow::{bail, Context, Result};
use clap::Args;

use crate::diag::Diags;
use crate::resolve::{self, pascal, ParamsType, ROOT_PARAMS};
use crate::scan::{self, parse_segment, Seg};

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

pub fn new_route(project: &Path, a: &NewArgs) -> Result<()> {
    let pkg = package_name(project)?;
    let app_dir = project.join("lib/app");

    let parts: Vec<String> = a
        .route
        .trim_matches('/')
        .split('/')
        .filter(|s| !s.is_empty())
        .map(|p| {
            if let Some(n) = p.strip_prefix('[').and_then(|p| p.strip_suffix(']')) {
                format!("${n}")
            } else if let Some(n) = p.strip_prefix(':') {
                format!("${n}")
            } else {
                p.to_string()
            }
        })
        .collect();
    let mut segs = vec![];
    for p in &parts {
        segs.push(parse_segment(p).map_err(anyhow::Error::msg)?);
    }
    let rel = parts.join("/");

    // Nearest existing ancestor and its params.
    let mut diags = Diags::default();
    let tree = scan::scan(&app_dir, &mut diags)?;
    let app = resolve::resolve(&tree, &mut diags);
    let mut existing = 0;
    while existing < parts.len() && app_dir.join(parts[..=existing].join("/")).is_dir() {
        existing += 1;
    }
    let anc_dir = parts[..existing].join("/");
    let parent: ParamsType = app
        .routes
        .iter()
        .find(|r| r.dir == anc_dir)
        .map(|r| r.params.clone())
        .context("couldn't resolve the parent folder; run `trellis check`")?;

    let fresh_dynamic: Vec<&str> = segs[existing..]
        .iter()
        .filter_map(|s| match s {
            Seg::Dynamic(n) => Some(n.as_str()),
            _ => None,
        })
        .collect();
    let stem = a.name.clone().unwrap_or_else(|| {
        let p = pascal(&rel);
        if p.is_empty() { "Home".into() } else { p }
    });

    let dir = app_dir.join(&rel);
    fs::create_dir_all(&dir)?;
    let mut files: Vec<(&str, String)> = vec![];

    // The leaf's params: its own params.dart, a generated class, or the parent's.
    let leaf_dynamic = matches!(segs.last(), Some(Seg::Dynamic(_))) && existing < parts.len();
    let (p_name, p_import) = if leaf_dynamic && fresh_dynamic.len() == 1 {
        let Seg::Dynamic(field) = segs.last().unwrap() else { unreachable!() };
        let name = format!("{stem}Params");
        let supers: Vec<String> = parent.fields.iter().map(|(n, _)| format!("required super.{n}")).collect();
        let args = [supers, vec![format!("required this.{field}")]].concat().join(", ");
        let konst = if parent.simple == ROOT_PARAMS { "const " } else { "" };
        files.push((
            "params.dart",
            format!(
                "import 'package:trellis/trellis.dart';\n{}\nclass {name} extends {} {{\n  {konst}{name}({{{args}}});\n\n  final String {field};\n}}\n",
                import_of(&pkg, &parent),
                parent.simple
            ),
        ));
        (name, "\nimport 'params.dart';\n".to_string())
    } else if !fresh_dynamic.is_empty() {
        let name = format!("{stem}Params");
        (name, format!("import 'package:{pkg}/app.g.dart';\n"))
    } else {
        (parent.simple.clone(), import_of(&pkg, &parent))
    };

    let material = "import 'package:flutter/material.dart';\nimport 'package:trellis/trellis.dart';\n";
    let (screen_t, body) = if a.data {
        ("String".to_string(), "Center(child: Text(data))")
    } else {
        (p_name.clone(), "Center(child: Text('$data'))")
    };
    let page_import = if a.data { "" } else { p_import.as_str() };
    files.push((
        "page.dart",
        format!(
            "{material}{page_import}\nclass {stem}Page extends Screen<{screen_t}> {{\n  const {stem}Page(super.data, {{super.key}});\n\n  @override\n  Widget build(BuildContext context, WidgetRef ref) => {body};\n}}\n"
        ),
    ));
    if a.data {
        files.push((
            "data.dart",
            format!(
                "import 'package:trellis/trellis.dart';\n{p_import}\nFuture<String> data(Ref ref, {p_name} params) async {{\n  return 'Hello from /{}';\n}}\n",
                rel.replace('$', "\\$")
            ),
        ));
    }
    if a.loading {
        files.push((
            "loading.dart",
            format!(
                "{material}{p_import}\nclass {stem}Loading extends Loading<{p_name}> {{\n  const {stem}Loading(super.params, {{super.key}});\n\n  @override\n  Widget build(BuildContext context, WidgetRef ref) =>\n      const Center(child: CircularProgressIndicator());\n}}\n"
            ),
        ));
    }
    if a.error {
        files.push((
            "error.dart",
            format!(
                "{material}{p_import}\nclass {stem}Error extends ErrorView<{p_name}> {{\n  const {stem}Error(super.params, super.failure, {{super.key}});\n\n  @override\n  Widget build(BuildContext context, WidgetRef ref) => Center(\n        child: TextButton(\n          onPressed: failure.retry,\n          child: Text('${{failure.error}} · retry'),\n        ),\n      );\n}}\n"
            ),
        ));
    }
    if a.layout {
        files.push((
            "layout.dart",
            format!(
                "{material}\nclass {stem}Layout extends Layout {{\n  const {stem}Layout(super.child, {{super.key}});\n\n  @override\n  Widget build(BuildContext context, WidgetRef ref) => child;\n}}\n"
            ),
        ));
    }
    if a.guard {
        files.push((
            "guard.dart",
            format!(
                "import 'package:trellis/trellis.dart';\n{p_import}\n/// Return a location to redirect, or null to let the navigation through.\nGuardResult guard(ProviderContainer c, {p_name} params) => null;\n"
            ),
        ));
    }

    let mut wrote = 0;
    for (name, body) in files {
        let path = dir.join(name);
        let shown = format!("lib/app/{rel}/{name}");
        if path.exists() {
            eprintln!("  skip  {shown} (exists)");
        } else {
            fs::write(&path, body)?;
            eprintln!("  new   {shown}");
            wrote += 1;
        }
    }
    if wrote == 0 {
        bail!("nothing to create");
    }
    Ok(())
}

fn import_of(pkg: &str, p: &ParamsType) -> String {
    match p.file.as_deref() {
        None => String::new(),
        Some("") => format!("import 'package:{pkg}/app.g.dart';\n"),
        Some(f) => format!("import 'package:{pkg}/app/{}';\n", f.replace('$', "\\$")),
    }
}

fn package_name(project: &Path) -> Result<String> {
    let spec = fs::read_to_string(project.join("pubspec.yaml")).context("reading pubspec.yaml")?;
    spec.lines()
        .find_map(|l| l.strip_prefix("name:").map(|n| n.trim().to_string()))
        .context("pubspec.yaml has no `name:`")
}
