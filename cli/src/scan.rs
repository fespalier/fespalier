//! Walks `lib/app/` into a tree of route folders.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

use crate::diag::Diags;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Kind {
    Page,
    Data,
    Loading,
    Error,
    Layout,
    Guard,
    Redirect,
    Transition,
    NotFound,
}

impl Kind {
    pub const ALL: [Kind; 9] = [
        Kind::Page,
        Kind::Data,
        Kind::Loading,
        Kind::Error,
        Kind::Layout,
        Kind::Guard,
        Kind::Redirect,
        Kind::Transition,
        Kind::NotFound,
    ];

    pub fn file(self) -> &'static str {
        match self {
            Kind::Page => "page.dart",
            Kind::Data => "data.dart",
            Kind::Loading => "loading.dart",
            Kind::Error => "error.dart",
            Kind::Layout => "layout.dart",
            Kind::Guard => "guard.dart",
            Kind::Redirect => "redirect.dart",
            Kind::Transition => "transition.dart",
            Kind::NotFound => "not_found.dart",
        }
    }

    fn from_file(name: &str) -> Option<Kind> {
        Kind::ALL.into_iter().find(|k| k.file() == name)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Seg {
    Static(String),
    Dynamic(String),
    /// `(name)`: groups routes (for a layout, loading or error view) without
    /// adding to the URL.
    Group(String),
}

#[derive(Debug)]
pub struct Node {
    /// Relative to `lib/app`, with `/` separators. Root is `""`.
    pub dir: String,
    pub seg: Option<Seg>,
    pub files: BTreeMap<Kind, String>,
    pub children: Vec<Node>,
}

impl Node {
    /// Path of a file relative to `lib/app`, e.g. `products/$id/page.dart`.
    pub fn rel(&self, kind: Kind) -> String {
        if self.dir.is_empty() {
            kind.file().to_string()
        } else {
            format!("{}/{}", self.dir, kind.file())
        }
    }
}

pub fn scan(app_dir: &Path, diags: &mut Diags) -> Result<Node> {
    let mut root = Node { dir: String::new(), seg: None, files: BTreeMap::new(), children: vec![] };
    fill(app_dir, &mut root, diags)?;
    Ok(root)
}

fn fill(dir: &Path, node: &mut Node, diags: &mut Diags) -> Result<()> {
    let mut entries: Vec<PathBuf> = fs::read_dir(dir)
        .with_context(|| format!("reading {}", dir.display()))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .collect();
    entries.sort();
    for path in entries {
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        if path.is_dir() {
            // `_components/` etc. are private: colocated, never routes.
            if name.starts_with('_') || name.starts_with('.') {
                continue;
            }
            let rel = if node.dir.is_empty() { name.clone() } else { format!("{}/{}", node.dir, name) };
            let seg = match parse_segment(&name) {
                Ok(s) => s,
                Err(msg) => {
                    diags.error(&rel, None, msg);
                    continue;
                }
            };
            let mut child = Node { dir: rel, seg: Some(seg), files: BTreeMap::new(), children: vec![] };
            fill(&path, &mut child, diags)?;
            node.children.push(child);
        } else if let Some(kind) = Kind::from_file(&name) {
            node.files.insert(kind, fs::read_to_string(&path)?);
        }
    }
    Ok(())
}

/// Names a dynamic segment can't take: they are the parameters fespalier fills
/// itself, or members of the generated route classes.
pub const RESERVED: [&str; 21] = [
    "data", "child", "navigationShell", "shell", "error", "stackTrace", "retry", "uri", "key", "location", "go",
    "push", "replace", "refresh", "watch", "read", "prefetch", "ref", "keepFor", "hashCode", "runtimeType",
];

/// Names a query parameter can't take either: the route class has a member of that name
/// (or a member's parameter shadows the field). The parameters fespalier fills itself
/// (`data`, `uri`, ...) are fine: those never reach the query.
pub const ROUTE_MEMBERS: [&str; 11] =
    ["location", "go", "push", "replace", "refresh", "watch", "read", "prefetch", "ref", "keepFor", "hashCode"];

pub fn parse_segment(name: &str) -> std::result::Result<Seg, String> {
    if let Some(p) = name.strip_prefix('$') {
        let valid = p.chars().next().is_some_and(|c| c.is_ascii_lowercase())
            && p.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
        if !valid {
            return Err(format!("`${p}`: a dynamic segment must be a lowerCamel Dart identifier, e.g. `$productId`"));
        }
        if RESERVED.contains(&p) {
            return Err(format!("`${p}` is reserved (fespalier fills parameters called `{p}` itself); pick another name"));
        }
        return Ok(Seg::Dynamic(p.to_string()));
    }
    let plain = |s: &str| !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '~'));
    if let Some(g) = name.strip_prefix('(').and_then(|n| n.strip_suffix(')')) {
        if !plain(g) {
            return Err(format!("`{name}`: a group name uses a-z, 0-9, - _ . ~, e.g. `(shop)`"));
        }
        return Ok(Seg::Group(g.to_string()));
    }
    if !plain(name) {
        return Err(format!(
            "`{name}` is not a valid URL segment (use a-z, 0-9, - _ . ~; `$name` for params, `(name)` for groups, `_name` for private folders)"
        ));
    }
    Ok(Seg::Static(name.to_string()))
}
