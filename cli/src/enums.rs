//! Enum segments and query parameters: `Category category`, `Sort? sort`, `List<Category> path`.
//!
//! A syntax tree can't say that `Category` is an enum: it may be a class, or come from a
//! package. So the type is only taken for one when its declaration is found, in the file that
//! names it (the view, `data.dart`, ...) or in a file that one imports or re-exports: relative
//! imports, and `package:` imports of the app's own package, which are read from `lib/`. Other
//! packages and `dart:` are not read, so an enum from one is an error that suggests a `String`.
//!
//! How the generated file names the type, and imports it, is `extra.rs`'s job, as for an
//! `extra`: this module only finds the declaration and tells the resolver what it found.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::rc::Rc;

use crate::config::{Config, Pubspec};
use crate::dart::{self, Module};
use crate::extra;
use crate::types::{self, Canonical, Declared, Scope};

/// An enum that was found.
#[derive(Debug, Clone, PartialEq)]
pub struct Found {
    /// The enum's name, as declared.
    pub name: String,
    /// The file that declares it, relative to the project: `lib/models/category.dart`.
    pub decl: String,
    /// The enum's constants, in declaration order.
    pub values: Vec<String>,
}

impl Found {
    /// What makes two spellings of a type the same enum: `Category` in one file and
    /// `m.Category` in another are one type when they name the same declaration.
    pub fn key(&self) -> String {
        format!("{}#{}", self.decl, self.name)
    }
}

/// What looking for an enum came to.
#[derive(Debug, Clone, PartialEq)]
pub enum Lookup {
    Found(Found),
    /// The name is private (`_Category`): the generated file can't name it.
    Private,
    /// Nothing that declares an enum of that name was found.
    Missing,
}

/// A library read for [`Libs`]: its parsed declarations, its imports and the source they came from.
struct Lib {
    module: Module,
    imports: Vec<extra::Import>,
    src: String,
}

impl Lib {
    fn new(src: &str) -> Lib {
        Lib {
            module: crate::parse_cache::parse(src),
            imports: extra::imports(src),
            src: src.to_string(),
        }
    }
}

/// The files enums are looked for in, other than the file that names them.
#[derive(Default)]
pub struct Libs {
    /// The project on disk. `None`: only the file that names the type is looked in.
    root: Option<PathBuf>,
    /// The pubspec's `name`, which `package:` imports of the app's own files start with.
    package: Option<String>,
    /// The app folder relative to the project (`lib/app`): view files are relative to it.
    app_dir: String,
    /// Parsed files by their path relative to the project; `None` for one that can't be read.
    files: RefCell<HashMap<String, Option<Rc<Lib>>>>,
    /// What was read from disk for `files`: the path and the source, `None` when it couldn't be.
    read: RefCell<Vec<(String, Option<String>)>>,
    /// Canonical forms already made, by the file they were written in and their text (since 0.21.0).
    canon: RefCell<HashMap<(String, String), Rc<Canonical>>>,
}

/// The files a [`Libs`] read from disk while resolving, with what was in them. `fsp watch` keeps
/// it beside the result of a run: the result holds while every one of them still reads the same.
#[derive(Debug, Default, PartialEq)]
pub struct Reads {
    package: Option<String>,
    files: Vec<(String, Option<String>)>,
}

impl Reads {
    /// The project paths read, sorted (a test checks which files a run needed).
    #[cfg(test)]
    pub fn paths(&self) -> Vec<&str> {
        self.files.iter().map(|(p, _)| p.as_str()).collect()
    }
}

impl Libs {
    /// For the app folder `app_dir` (`<project>/lib/app`, as `Config::app_dir` says).
    pub fn for_app(app_dir: &Path, cfg: &Config) -> Libs {
        let project = app_dir.ancestors().nth(cfg.app_dir.split('/').count());
        let package = project
            .and_then(|p| Pubspec::load(p).ok())
            .and_then(|p| p.name);
        Libs {
            root: project.map(Path::to_path_buf),
            package,
            app_dir: cfg.app_dir.clone(),
            ..Libs::default()
        }
    }

    /// The files read from disk so far, for [`Libs::unchanged_since`].
    pub fn reads(&self) -> Reads {
        let mut files = self.read.borrow().clone();
        files.sort();
        Reads {
            package: self.package.clone(),
            files,
        }
    }

    /// Whether everything `reads` saw reads the same now, and the package is the same one.
    /// It compares contents: the files are few and small.
    pub fn unchanged_since(&self, reads: &Reads) -> bool {
        self.package == reads.package
            && reads.files.iter().all(|(path, src)| {
                let now = self
                    .root
                    .as_ref()
                    .and_then(|root| std::fs::read_to_string(root.join(path)).ok());
                now == *src
            })
    }

    /// Looks for the enum `ty` (`Category` or `m.Category`, as written) as the file `file`
    /// (relative to the app folder, holding `src`) names it: declared in the file itself, or in
    /// a library it imports (through the prefix `m`, for a prefixed name) or that library exports.
    /// A typedef of an enum (`typedef Cat = Category;`) is followed to the enum (since 0.21.0).
    pub fn find(&self, file: &str, src: &str, ty: &str) -> Lookup {
        let (prefix, name) = split(ty);
        if name.starts_with('_') {
            return Lookup::Private;
        }
        let from = self.own(file, src);
        match self.find_from(&from, prefix, name, 0) {
            Some(found) => Lookup::Found(found),
            None => Lookup::Missing,
        }
    }

    /// Records the file the tree holds (`src`, as scanned) under its project path, and returns that
    /// path. Whatever is on disk is not read for it.
    fn own(&self, file: &str, src: &str) -> String {
        let from = format!("{}/{file}", self.app_dir);
        self.files
            .borrow_mut()
            .entry(from.clone())
            .or_insert_with(|| Some(Rc::new(Lib::new(src))));
        from
    }

    /// The enum `name` as the library `path` sees it through `prefix`: declared in it, or a typedef
    /// of one in it, or in an import or export of it (since 0.21.0 the typedef's own file looks it
    /// up as the page did). The first enum found wins; a name that is not an enum is skipped.
    fn find_from(
        &self,
        path: &str,
        prefix: Option<&str>,
        name: &str,
        depth: usize,
    ) -> Option<Found> {
        if depth > DEPTH {
            return None;
        }
        if prefix.is_none()
            && let Some(found) = self.enum_here(path, name, depth)
        {
            return Some(found);
        }
        let lib = self.lib(path)?;
        let mut seen = HashSet::new();
        for import in lib
            .imports
            .iter()
            .filter(|i| i.prefix.as_deref() == prefix && i.combinators.admits(name))
        {
            let Some(target) = self.locate(path, &import.uri) else {
                continue;
            };
            if let Some(found) = self.enum_in(&target, name, &mut seen, depth) {
                return Some(found);
            }
        }
        None
    }

    /// The enum `name` that the library `path` declares, or the enum a typedef of it names.
    fn enum_here(&self, path: &str, name: &str, depth: usize) -> Option<Found> {
        let lib = self.lib(path)?;
        if let Some(values) = constants(&lib.module, name) {
            return Some(Found {
                name: name.to_string(),
                decl: path.to_string(),
                values,
            });
        }
        let typedef = lib.module.typedefs.iter().find(|t| t.name == name)?;
        if !is_candidate(&typedef.ty.text) {
            return None;
        }
        let (prefix, target) = split(&typedef.ty.text);
        self.find_from(path, prefix, target, depth + 1)
    }

    /// The enum `name` that the library at `path` or one of the libraries it exports declares.
    fn enum_in(
        &self,
        path: &str,
        name: &str,
        seen: &mut HashSet<String>,
        depth: usize,
    ) -> Option<Found> {
        if !seen.insert(path.to_string()) {
            return None;
        }
        if let Some(found) = self.enum_here(path, name, depth) {
            return Some(found);
        }
        let lib = self.lib(path)?;
        lib.module
            .exports
            .iter()
            .filter(|e| e.combinators.admits(name))
            .find_map(|e| self.enum_in(&self.locate(path, &e.uri)?, name, seen, depth))
    }

    /// The library at `path`, parsed and read on first use (`None` when it can't be read).
    fn lib(&self, path: &str) -> Option<Rc<Lib>> {
        if let Some(lib) = self.files.borrow().get(path) {
            return lib.clone();
        }
        let src = self
            .root
            .as_ref()
            .and_then(|root| std::fs::read_to_string(root.join(path)).ok());
        let lib = src.as_deref().map(|src| Rc::new(Lib::new(src)));
        if self.root.is_some() {
            self.read.borrow_mut().push((path.to_string(), src));
        }
        self.files
            .borrow_mut()
            .insert(path.to_string(), lib.clone());
        lib
    }

    /// Where `uri`, as written in the file `from`, is: relative to the project. `None` for what
    /// isn't in this package: `dart:`, another package.
    fn locate(&self, from: &str, uri: &str) -> Option<String> {
        if let Some(rest) = uri.strip_prefix("package:") {
            let (package, path) = rest.split_once('/')?;
            return (Some(package) == self.package.as_deref()).then(|| format!("lib/{path}"));
        }
        if uri.contains(':') {
            return None;
        }
        let mut parts: Vec<&str> = from.split('/').collect();
        parts.pop();
        for seg in uri.split('/') {
            match seg {
                "" | "." => {}
                ".." => {
                    parts.pop()?;
                }
                s => parts.push(s),
            }
        }
        Some(parts.join("/"))
    }

    /// The canonical form of `text`, written in the tree file `file` (relative to the app folder,
    /// holding `src`): typedefs followed and import prefixes dropped (since 0.21.0). Memoized.
    pub fn canonical(&self, file: &str, src: &str, text: &str) -> Rc<Canonical> {
        let from = self.own(file, src);
        self.canonical_in(&from, text)
    }

    /// The canonical form of `text` as the file at the project path `path` sees it (memoized).
    pub fn canonical_in(&self, path: &str, text: &str) -> Rc<Canonical> {
        let key = (path.to_string(), text.to_string());
        if let Some(c) = self.canon.borrow().get(&key) {
            return c.clone();
        }
        let c = Rc::new(types::canonical(self, path, text));
        self.canon.borrow_mut().insert(key, c.clone());
        c
    }

    /// The record typedef `ty` names (`PayFields`, `f.PayFields`) as the file `file` (relative to
    /// the app folder, holding `src`) sees it, and the project path of the file that declares it
    /// (since 0.21.0). A typedef of another typedef is followed to the record.
    pub fn typedef_record(&self, file: &str, src: &str, ty: &str) -> Option<(dart::Ty, String)> {
        let from = self.own(file, src);
        let (prefix, name) = split(ty);
        self.record_from(&from, prefix, name, 0)
    }

    fn record_from(
        &self,
        path: &str,
        prefix: Option<&str>,
        name: &str,
        depth: usize,
    ) -> Option<(dart::Ty, String)> {
        if depth > DEPTH {
            return None;
        }
        let declared = self.declared(path, prefix, name)?;
        declared.alias.as_ref()?;
        let lib = self.lib(&declared.decl)?;
        let typedef = lib.module.typedefs.iter().find(|t| t.name == name)?;
        if typedef.ty.record.is_some() {
            return Some((typedef.ty.clone(), declared.decl));
        }
        if !is_candidate(&typedef.ty.text) {
            return None;
        }
        let (p, n) = split(&typedef.ty.text);
        self.record_from(&declared.decl, p, n, depth + 1)
    }
}

/// How deep typedefs are followed: a typedef of a typedef of ..., and a cycle, stop here.
const DEPTH: usize = 8;

impl types::Scope for Libs {
    /// What `name` names as the file `path` sees it, through `prefix`: a declaration of that file,
    /// else one of the libraries its matching imports bring in (their exports too). A private name
    /// is not visible through an import.
    fn declared(&self, path: &str, prefix: Option<&str>, name: &str) -> Option<Declared> {
        let lib = self.lib(path)?;
        if prefix.is_none()
            && let Some(d) = self.declared_here(path, &lib, name)
        {
            return Some(d);
        }
        if name.starts_with('_') {
            return None;
        }
        for import in lib
            .imports
            .iter()
            .filter(|i| i.prefix.as_deref() == prefix && i.combinators.admits(name))
        {
            let Some(target) = self.locate(path, &import.uri) else {
                continue;
            };
            let mut seen = HashSet::new();
            if let Some(d) = self.exported(&target, name, &mut seen) {
                return Some(d);
            }
        }
        None
    }
}

impl Libs {
    /// The declaration of `name` in the library at `path` or in one of the libraries it exports.
    fn exported(&self, path: &str, name: &str, seen: &mut HashSet<String>) -> Option<Declared> {
        if !seen.insert(path.to_string()) {
            return None;
        }
        let lib = self.lib(path)?;
        if let Some(d) = self.declared_here(path, &lib, name) {
            return Some(d);
        }
        lib.module
            .exports
            .iter()
            .filter(|e| e.combinators.admits(name))
            .find_map(|e| self.exported(&self.locate(path, &e.uri)?, name, seen))
    }

    /// What the library at `path` declares as `name`: an enum, a typedef (with what it aliases), or
    /// any other type (a class, a mixin, an extension type, a generic typedef) the text declares.
    fn declared_here(&self, path: &str, lib: &Lib, name: &str) -> Option<Declared> {
        let alias = if lib.module.enums.iter().any(|e| e.name == name) {
            None
        } else if let Some(t) = lib.module.typedefs.iter().find(|t| t.name == name) {
            Some(t.ty.text.clone())
        } else if extra::declares(&lib.src, name) {
            None
        } else {
            return None;
        };
        Some(Declared {
            decl: path.to_string(),
            name: name.to_string(),
            alias,
        })
    }
}

/// The constants of the enum `name` that `module` declares, `None` when it declares none. A file
/// the grammar could not read fully gives an empty list: the constants it found may not be all
/// of them, and a list that is not whole must not be used to judge a value.
fn constants(module: &Module, name: &str) -> Option<Vec<String>> {
    let e = module.enums.iter().find(|e| e.name == name)?;
    Some(if module.parse_error.is_some() {
        vec![]
    } else {
        e.values.clone()
    })
}

/// `m.Category` → (`m`, `Category`).
fn split(ty: &str) -> (Option<&str>, &str) {
    match ty.split_once('.') {
        Some((prefix, name)) => (Some(prefix), name),
        None => (None, ty),
    }
}

/// Whether `ty` could name an enum: a type name, with or without an import prefix, that isn't
/// one `dart:core` gives every file (`Object`, `DateTime`, ...). Whether it does is up to
/// [`Libs::find`].
pub fn is_candidate(ty: &str) -> bool {
    let ident = |s: &str| {
        !s.is_empty()
            && s.chars()
                .all(|c| c.is_alphanumeric() || c == '_' || c == '$')
    };
    let (prefix, name) = split(ty);
    ident(name)
        && prefix.is_none_or(ident)
        && name.starts_with(|c: char| c.is_uppercase() || c == '_')
        && !extra::is_core(name)
}

/// A query parameter's type that isn't a plain one: `Sort?`, `List<Sort>` or `List<Sort>?`
/// → the bare type, and whether it is a list.
pub fn query_shape(ty: &str) -> Option<(&str, bool)> {
    if let Some(inner) = ty.strip_suffix('?').filter(|i| is_candidate(i)) {
        return Some((inner, false));
    }
    let list = ty.strip_suffix('?').unwrap_or(ty);
    let inner = list.strip_prefix("List<")?.strip_suffix('>')?;
    is_candidate(inner).then_some((inner, true))
}

/// The enum in a segment's or query parameter's type, as the generated file spells it
/// (`_i3.Category`, `List<_i3.Category>`, `Sort?`): the bare type, or `None` when the type is one
/// of the plain ones (`int?`, `List<String>`).
pub fn enum_base(ty: &str) -> Option<&str> {
    let ty = ty.strip_suffix('?').unwrap_or(ty);
    let ty = ty
        .strip_prefix("List<")
        .and_then(|t| t.strip_suffix('>'))
        .unwrap_or(ty);
    (!matches!(
        ty,
        "String" | "int" | "double" | "num" | "bool" | "DateTime"
    ))
    .then_some(ty)
}
