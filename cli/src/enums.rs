//! Enum segments and query parameters: `Category category`, `Sort? sort`, `List<Category> path`.
//!
//! A syntax tree can't say that `Category` is an enum: it may be a class, or come from a
//! package. So the type is only taken for one when its declaration is found, in the file that
//! names it (the view, `data.dart`, ...) or in a file that one imports or re-exports: relative
//! imports, and `package:` imports of the app's own package, which are read from `lib/`, or since
//! 0.22.0 of one of its `path:` dependencies (`packages.rs`), read from that package's `lib/` and
//! known by its package URI (`package:shared/src/ids.dart`). Other packages (hosted, `git:`, the
//! SDK's) and `dart:` are not read, so an enum from one is an error that suggests a `String`.
//!
//! How the generated file names the type, and imports it, is `extra.rs`'s job, as for an
//! `extra`: this module only finds the declaration and tells the resolver what it found.

use std::cell::{OnceCell, RefCell};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::rc::Rc;

use crate::config::{Config, Pubspec};
use crate::dart::{self, Module};
use crate::extra;
use crate::packages::Packages;
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
    /// It was reached through a typedef (`typedef Cat = Category;`), not by its own name (since 0.21.0).
    pub via_typedef: bool,
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

/// What the lookups of a run cost, for a test to pin (the thread's total so far).
#[cfg(test)]
#[derive(Debug, Default, Clone, Copy, PartialEq)]
pub struct Work {
    /// Libraries parsed.
    pub parses: usize,
    /// Libraries searched for the declaration of a name.
    pub probes: usize,
}

#[cfg(test)]
thread_local! {
    static WORK: std::cell::Cell<Work> = const { std::cell::Cell::new(Work { parses: 0, probes: 0 }) };
}

/// The thread's lookups so far (see [`Work`]).
#[cfg(test)]
pub fn work() -> Work {
    WORK.get()
}

/// Counts one more of a [`Work`] field in a test build; nothing otherwise.
macro_rules! count {
    ($field:ident) => {
        #[cfg(test)]
        {
            let mut w = WORK.get();
            w.$field += 1;
            WORK.set(w);
        }
    };
}

/// A library read for [`Libs`]: its source, and what is made of it only when a lookup needs it. A
/// lookup of a name the source does not mention parses nothing (since 0.21.0).
struct Lib {
    src: String,
    imports: OnceCell<Vec<extra::Import>>,
    module: OnceCell<Module>,
}

impl Lib {
    fn new(src: &str) -> Lib {
        Lib {
            src: src.to_string(),
            imports: OnceCell::new(),
            module: OnceCell::new(),
        }
    }

    /// The `import`s of the source.
    fn imports(&self) -> &[extra::Import] {
        self.imports.get_or_init(|| extra::imports(&self.src))
    }

    /// The declarations of the source, parsed on first use.
    fn module(&self) -> &Module {
        self.module.get_or_init(|| {
            count!(parses);
            crate::parse_cache::parse(&self.src)
        })
    }

    /// What the library re-exports. A source with no `export` in it has none, and is not parsed.
    fn exports(&self) -> &[dart::Export] {
        if self.src.contains("export") {
            &self.module().exports
        } else {
            &[]
        }
    }

    /// Whether the source may declare a type called `name`: the name follows `class`, `enum`,
    /// `typedef`, `mixin` or `type` somewhere in it (comments and strings included, so a `true` is
    /// not a promise). A `false` is: every declaration of a type is spelled that way, and nothing
    /// is parsed to find out.
    fn may_declare(&self, name: &str) -> bool {
        count!(probes);
        let ident = |c: char| c.is_alphanumeric() || c == '_' || c == '$';
        self.src.match_indices(name).any(|(at, _)| {
            let (before, after) = (&self.src[..at], &self.src[at + name.len()..]);
            if before.ends_with(ident) || after.starts_with(ident) {
                return false;
            }
            let before = before.trim_end();
            let word = before.rsplit(|c: char| !ident(c)).next().unwrap_or("");
            // A comment between the keyword and the name is not looked into: it may be one.
            before.ends_with("*/")
                || matches!(word, "class" | "enum" | "typedef" | "mixin" | "type")
        })
    }
}

/// A library path, an import prefix and a name: what a lookup of a type name is made with.
type DeclaredKey = (String, Option<String>, String);

/// The files enums are looked for in, other than the file that names them.
#[derive(Default)]
pub struct Libs {
    /// The project on disk. `None`: only the file that names the type is looked in.
    root: Option<PathBuf>,
    /// The pubspec's `name`, which `package:` imports of the app's own files start with.
    package: Option<String>,
    /// The app folder relative to the project (`lib/app`): view files are relative to it.
    app_dir: String,
    /// The path dependencies whose files are read as `package:<name>/...` (since 0.22.0).
    packages: Packages,
    /// Parsed files by their path relative to the project; `None` for one that can't be read.
    files: RefCell<HashMap<String, Option<Rc<Lib>>>>,
    /// What was read from disk for `files`: the path and the source, `None` when it couldn't be.
    read: RefCell<Vec<(String, Option<String>)>>,
    /// Canonical forms already made, by the file they were written in and their text (since 0.21.0).
    canon: RefCell<HashMap<(String, String), Rc<Canonical>>>,
    /// What a library sees under a prefix by a name, already looked up (since 0.21.0).
    declared: RefCell<HashMap<DeclaredKey, Option<Declared>>>,
    /// What a library and the ones it exports declare as a name, by the library's path and the name:
    /// the walk through a barrel is made once, not once per page that imports it (since 0.21.0).
    exported: RefCell<HashMap<(String, String), Option<Declared>>>,
    /// The enum a library and the ones it exports declare as a name, by the same key.
    enums: RefCell<HashMap<(String, String), Option<Found>>>,
}

/// The files a [`Libs`] read from disk while resolving, with what was in them, and the path packages
/// it read them from (since 0.22.0). `fsp watch` keeps it beside the result of a run: the result
/// holds while the pubspecs give the same packages and every file still reads the same.
#[derive(Debug, Default, PartialEq)]
pub struct Reads {
    package: Option<String>,
    packages: Packages,
    files: Vec<(String, Option<String>)>,
}

impl Reads {
    /// The folders that hold the files read, as paths under `project` (since 0.22.0): `fsp watch`
    /// watches those outside `lib/`, a path dependency's.
    pub fn folders(&self, project: &Path) -> std::collections::BTreeSet<PathBuf> {
        self.files
            .iter()
            .filter_map(|(path, _)| {
                let file = match path.strip_prefix("package:") {
                    Some(rest) => {
                        let (package, file) = rest.split_once('/')?;
                        self.packages.root(package)?.join("lib").join(file)
                    }
                    None => project.join(path),
                };
                file.parent().map(Path::to_path_buf)
            })
            .collect()
    }

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
        let packages = project
            .map(|p| Packages::read(p, package.as_deref()))
            .unwrap_or_default();
        Libs {
            root: project.map(Path::to_path_buf),
            package,
            packages,
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
            packages: self.packages.clone(),
            files,
        }
    }

    /// Whether everything `reads` saw reads the same now, and the package is the same one.
    /// It compares contents: the files are few and small.
    pub fn unchanged_since(&self, reads: &Reads) -> bool {
        self.package == reads.package
            && self.packages == reads.packages
            && reads.files.iter().all(|(path, src)| {
                let now = self
                    .disk(path)
                    .and_then(|p| std::fs::read_to_string(p).ok());
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
        for import in lib
            .imports()
            .iter()
            .filter(|i| i.prefix.as_deref() == prefix && i.combinators.admits(name))
        {
            let Some(target) = self.locate(path, &import.uri) else {
                continue;
            };
            if let Some(found) = self.enum_exported(&target, name, depth) {
                return Some(found);
            }
        }
        None
    }

    /// The enum `name` that the library at `path` or one of the libraries it exports declares. The
    /// walk through the exports of a library is made once per name, not once per file that imports
    /// it (a lookup further down a chain of typedefs is not kept: it depends on how deep it is).
    fn enum_exported(&self, path: &str, name: &str, depth: usize) -> Option<Found> {
        if depth > 0 {
            return self.enum_in(path, name, &mut HashSet::new(), depth);
        }
        let key = (path.to_string(), name.to_string());
        if let Some(hit) = self.enums.borrow().get(&key) {
            return hit.clone();
        }
        let found = self.enum_in(path, name, &mut HashSet::new(), depth);
        self.enums.borrow_mut().insert(key, found.clone());
        found
    }

    /// The enum `name` that the library `path` declares, or the enum a typedef of it names.
    fn enum_here(&self, path: &str, name: &str, depth: usize) -> Option<Found> {
        let lib = self.lib(path)?;
        if !lib.may_declare(name) {
            return None;
        }
        if let Some(values) = constants(lib.module(), name) {
            return Some(Found {
                name: name.to_string(),
                decl: path.to_string(),
                values,
                via_typedef: false,
            });
        }
        let typedef = lib.module().typedefs.iter().find(|t| t.name == name)?;
        if !is_candidate(&typedef.ty.text) {
            return None;
        }
        let (prefix, target) = split(&typedef.ty.text);
        self.find_from(path, prefix, target, depth + 1)
            .map(|found| Found {
                via_typedef: true,
                ..found
            })
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
        lib.exports()
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
            .disk(path)
            .and_then(|p| std::fs::read_to_string(p).ok());
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
            if Some(package) == self.package.as_deref() {
                return Some(format!("lib/{path}"));
            }
            // A path dependency's file, by its package URI (since 0.22.0).
            self.packages.root(package)?;
            return join("_", path).map(|p| format!("package:{package}/{p}"));
        }
        if uri.contains(':') {
            return None;
        }
        // A relative import in a path dependency's file stays in that package's lib/.
        if let Some(rest) = from.strip_prefix("package:") {
            let (package, file) = rest.split_once('/')?;
            return join(file, uri).map(|p| format!("package:{package}/{p}"));
        }
        join(from, uri)
    }

    /// Where the file `path` is on disk: under the project, or for `package:<name>/...` under that
    /// path dependency's `lib/` (since 0.22.0).
    fn disk(&self, path: &str) -> Option<std::path::PathBuf> {
        match path.strip_prefix("package:") {
            Some(rest) => {
                let (package, file) = rest.split_once('/')?;
                Some(self.packages.root(package)?.join("lib").join(file))
            }
            None => Some(self.root.as_ref()?.join(path)),
        }
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
        let typedef = lib.module().typedefs.iter().find(|t| t.name == name)?;
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

/// `uri`, relative to the file `from`: `None` when it climbs above the first folder of `from`.
fn join(from: &str, uri: &str) -> Option<String> {
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

impl types::Scope for Libs {
    /// What `name` names as the file `path` sees it, through `prefix`: a declaration of that file,
    /// else one of the libraries its matching imports bring in (their exports too). A private name
    /// is not visible through an import. Memoized.
    fn declared(&self, path: &str, prefix: Option<&str>, name: &str) -> Option<Declared> {
        let key: DeclaredKey = (
            path.to_string(),
            prefix.map(str::to_string),
            name.to_string(),
        );
        if let Some(hit) = self.declared.borrow().get(&key) {
            return hit.clone();
        }
        let found = self.declared_through(path, prefix, name);
        self.declared.borrow_mut().insert(key, found.clone());
        found
    }
}

impl Libs {
    fn declared_through(&self, path: &str, prefix: Option<&str>, name: &str) -> Option<Declared> {
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
            .imports()
            .iter()
            .filter(|i| i.prefix.as_deref() == prefix && i.combinators.admits(name))
        {
            let Some(target) = self.locate(path, &import.uri) else {
                continue;
            };
            if let Some(d) = self.exported_once(&target, name) {
                return Some(d);
            }
        }
        None
    }

    /// The declaration of `name` in the library at `path` or in one of the libraries it exports,
    /// found once per library and name: a barrel that a hundred pages import is walked once.
    fn exported_once(&self, path: &str, name: &str) -> Option<Declared> {
        let key = (path.to_string(), name.to_string());
        if let Some(hit) = self.exported.borrow().get(&key) {
            return hit.clone();
        }
        let found = self.exported(path, name, &mut HashSet::new());
        self.exported.borrow_mut().insert(key, found.clone());
        found
    }

    /// The declaration of `name` in the library at `path` or in one of the libraries it exports.
    fn exported(&self, path: &str, name: &str, seen: &mut HashSet<String>) -> Option<Declared> {
        if !seen.insert(path.to_string()) {
            return None;
        }
        let lib = self.lib(path)?;
        if let Some(d) = self.declared_here(path, &lib, name) {
            return Some(d);
        }
        lib.exports()
            .iter()
            .filter(|e| e.combinators.admits(name))
            .find_map(|e| self.exported(&self.locate(path, &e.uri)?, name, seen))
    }

    /// What the library at `path` declares as `name`: an enum, a typedef (with what it aliases), or
    /// any other type (a class, a mixin, an extension type, a generic typedef) the text declares.
    /// A source that does not spell a declaration of the name is not parsed.
    fn declared_here(&self, path: &str, lib: &Lib, name: &str) -> Option<Declared> {
        if !lib.may_declare(name) {
            return None;
        }
        let module = lib.module();
        let alias = if module.enums.iter().any(|e| e.name == name) {
            None
        } else if let Some(t) = module.typedefs.iter().find(|t| t.name == name) {
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
