//! Walks `lib/app/` into a tree of route folders.

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

use crate::dart::Span;
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
    Meta,
    Route,
    Navigator,
    Present,
    /// The app folder's own `extra_codec.dart`: read at the root only.
    ExtraCodec,
}

impl Kind {
    pub const ALL: [Kind; 14] = [
        Kind::Page,
        Kind::Data,
        Kind::Loading,
        Kind::Error,
        Kind::Layout,
        Kind::Guard,
        Kind::Redirect,
        Kind::Transition,
        Kind::NotFound,
        Kind::Meta,
        Kind::Route,
        Kind::Navigator,
        Kind::Present,
        Kind::ExtraCodec,
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
            Kind::Meta => "meta.dart",
            Kind::Route => "route.dart",
            Kind::Navigator => "navigator.dart",
            Kind::Present => "present.dart",
            Kind::ExtraCodec => "extra_codec.dart",
        }
    }

    /// The kind's file name in kebab-case: `not-found.dart`. The same as [`Kind::file`]
    /// for the kinds whose name is one word.
    pub fn kebab_file(self) -> String {
        self.file().replace('_', "-")
    }

    /// The kind a file name spells, in either style. Reading accepts both whatever
    /// `file_style` says: that only picks what `fsp init` and `fsp new` write. Every
    /// multi-word kind gets this, so a future one needs nothing here.
    fn from_file(name: &str) -> Option<Kind> {
        Kind::ALL
            .into_iter()
            .find(|k| k.file() == name || k.kebab_file() == name)
    }
}

/// How the files fespalier writes name a multi-word kind: `not_found.dart` or `not-found.dart`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FileStyle {
    #[default]
    Snake,
    Kebab,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Seg {
    Static(String),
    Dynamic(String),
    /// `$$name` (one or more remaining segments) or `$$$name` (zero or more, the
    /// flag): the rest of the path, as a `List<String>` (or a `List` of another
    /// simple type: see `resolve::CATCH_ALL_ITEMS`).
    CatchAll(String, bool),
    /// `(name)`: groups routes (for a layout, loading or error view) without
    /// adding to the URL.
    Group(String),
}

/// `PartialEq` lets `fsp watch` tell that a run saw exactly the tree of the run before.
#[derive(Debug, PartialEq)]
pub struct Node {
    /// Relative to `lib/app`, with `/` separators. Root is `""`.
    pub dir: String,
    pub seg: Option<Seg>,
    pub files: BTreeMap<Kind, String>,
    /// The name a file has on disk when it isn't the kind's `snake_case` one (`not-found.dart`).
    pub spelled: BTreeMap<Kind, String>,
    pub children: Vec<Node>,
}

impl Node {
    fn in_dir(&self, name: &str) -> String {
        if self.dir.is_empty() {
            name.to_string()
        } else {
            format!("{}/{}", self.dir, name)
        }
    }

    /// Path of a file relative to `lib/app`, e.g. `products/$id/page.dart`, as it is
    /// spelled on disk.
    pub fn rel(&self, kind: Kind) -> String {
        match self.spelled.get(&kind) {
            Some(name) => self.in_dir(name),
            None => self.in_dir(kind.file()),
        }
    }
}

/// A span over the first line of a file: where a diagnostic about the whole file points.
fn first_line(src: &str) -> Span {
    Span {
        line: 1,
        bytes: 0..src.find('\n').unwrap_or(src.len()),
    }
}

pub fn scan(app_dir: &Path, diags: &mut Diags) -> Result<Node> {
    let mut root = Node {
        dir: String::new(),
        seg: None,
        files: BTreeMap::new(),
        spelled: BTreeMap::new(),
        children: vec![],
    };
    fill(app_dir, &mut root, diags)?;
    Ok(root)
}

fn fill(dir: &Path, node: &mut Node, diags: &mut Diags) -> Result<()> {
    // The entry's own file type saves a `stat` per entry; only a symlink has to be followed.
    let mut entries: Vec<(OsString, PathBuf, bool)> = fs::read_dir(dir)
        .with_context(|| format!("reading {}", dir.display()))?
        .filter_map(|e| {
            let e = e.ok()?;
            let path = e.path();
            let is_dir = match e.file_type().ok()? {
                t if t.is_symlink() => path.is_dir(),
                t => t.is_dir(),
            };
            Some((e.file_name(), path, is_dir))
        })
        .collect();
    entries.sort();
    for (name, path, is_dir) in entries {
        let name = name.to_string_lossy().to_string();
        if is_dir {
            // `_components/` etc. are private: colocated, never routes.
            if name.starts_with('_') || name.starts_with('.') {
                continue;
            }
            let rel = if node.dir.is_empty() {
                name.clone()
            } else {
                format!("{}/{}", node.dir, name)
            };
            let seg = match parse_segment(&name) {
                Ok(s) => s,
                Err(msg) => {
                    diags.error(&rel, None, msg);
                    continue;
                }
            };
            let mut child = Node {
                dir: rel,
                seg: Some(seg),
                files: BTreeMap::new(),
                spelled: BTreeMap::new(),
                children: vec![],
            };
            fill(&path, &mut child, diags)?;
            node.children.push(child);
        } else if let Some(kind) = Kind::from_file(&name) {
            let src = fs::read_to_string(&path)?;
            if node.files.contains_key(&kind) {
                // `not_found.dart` and `not-found.dart` are one kind: point at each file,
                // and keep the first.
                let other = node
                    .spelled
                    .get(&kind)
                    .cloned()
                    .unwrap_or_else(|| kind.file().to_string());
                let same = |a: &str, b: &str| {
                    format!(
                        "`{a}` and `{b}` are the same view and both are in this folder; keep one"
                    )
                };
                let theirs = fs::read_to_string(path.with_file_name(&other)).unwrap_or_default();
                diags.error(
                    &node.in_dir(&name),
                    Some(&first_line(&src)),
                    same(&name, &other),
                );
                diags.error(
                    &node.in_dir(&other),
                    Some(&first_line(&theirs)),
                    same(&other, &name),
                );
                continue;
            }
            if name != kind.file() {
                node.spelled.insert(kind, name);
            }
            node.files.insert(kind, src);
        }
    }
    Ok(())
}

/// Names a dynamic segment can't take: they are the parameters fespalier fills
/// itself, or members of the generated route classes.
pub const RESERVED: [&str; 25] = [
    "data",
    "child",
    "navigationShell",
    "shell",
    "error",
    "stackTrace",
    "retry",
    "uri",
    "key",
    "location",
    "go",
    "push",
    "replace",
    "refresh",
    "watch",
    "read",
    "prefetch",
    "ref",
    "keepFor",
    "hashCode",
    "runtimeType",
    "extra",
    "of",
    "maybeOf",
    "copyWith",
];

/// Names a query parameter can't take either: the route class has a member of that name
/// (or a member's parameter shadows the field). The parameters fespalier fills itself
/// (`data`, `uri`, ...) are fine: those never reach the query.
pub const ROUTE_MEMBERS: [&str; 14] = [
    "location", "go", "push", "replace", "refresh", "watch", "read", "prefetch", "ref", "keepFor",
    "hashCode", "of", "maybeOf", "copyWith",
];

/// Names a key of a section's `data.dart` can't take: the section's typed handle
/// (`AccountSection.watch(ref, ...)`) takes its keys as named parameters next to these.
pub const SECTION_MEMBERS: [&str; 11] = [
    "location", "go", "push", "replace", "refresh", "watch", "read", "prefetch", "ref", "keepFor",
    "hashCode",
];

pub fn parse_segment(name: &str) -> std::result::Result<Seg, String> {
    // `$$$rest` (zero or more) and `$$rest` (one or more): the rest of the path.
    for (marks, optional) in [("$$$", true), ("$$", false)] {
        if let Some(p) = name.strip_prefix(marks) {
            let valid = p.chars().next().is_some_and(|c| c.is_ascii_lowercase())
                && p.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
            if !valid {
                return Err(format!(
                    "`{name}`: a catch-all segment must be a lowerCamel Dart identifier, e.g. `$$rest` (one or more segments) or `$$$rest` (zero or more)"
                ));
            }
            if RESERVED.contains(&p) {
                return Err(format!(
                    "`{name}` is reserved (fespalier fills parameters called `{p}` itself); pick another name"
                ));
            }
            return Ok(Seg::CatchAll(p.to_string(), optional));
        }
    }
    if let Some(p) = name.strip_prefix('$') {
        let valid = p.chars().next().is_some_and(|c| c.is_ascii_lowercase())
            && p.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
        if !valid {
            return Err(format!(
                "`${p}`: a dynamic segment must be a lowerCamel Dart identifier, e.g. `$productId`"
            ));
        }
        if RESERVED.contains(&p) {
            return Err(format!(
                "`${p}` is reserved (fespalier fills parameters called `{p}` itself); pick another name"
            ));
        }
        return Ok(Seg::Dynamic(p.to_string()));
    }
    let plain = |s: &str| {
        !s.is_empty()
            && s.chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '~'))
    };
    if let Some(g) = name.strip_prefix('(').and_then(|n| n.strip_suffix(')')) {
        if !plain(g) {
            return Err(format!(
                "`{name}`: a group name uses a-z, A-Z, 0-9, - _ . ~, e.g. `(shop)`"
            ));
        }
        return Ok(Seg::Group(g.to_string()));
    }
    if !plain(name) {
        return Err(format!(
            "`{name}` is not a valid URL segment (use a-z, A-Z, 0-9, - _ . ~; `$name` for params, `(name)` for groups, `_name` for private folders)"
        ));
    }
    Ok(Seg::Static(name.to_string()))
}
