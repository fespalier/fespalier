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
use crate::dart::Module;
use crate::extra;

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
    files: RefCell<HashMap<String, Option<Rc<Module>>>>,
    /// What was read from disk for `files`: the path and the source, `None` when it couldn't be.
    read: RefCell<Vec<(String, Option<String>)>>,
}

/// The files a [`Libs`] read from disk while resolving, with what was in them. `fsp watch` keeps
/// it beside the result of a run: the result holds while every one of them still reads the same.
#[derive(Debug, Default, PartialEq)]
pub struct Reads {
    package: Option<String>,
    files: Vec<(String, Option<String>)>,
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
    pub fn find(&self, file: &str, src: &str, ty: &str) -> Lookup {
        let (prefix, name) = split(ty);
        if name.starts_with('_') {
            return Lookup::Private;
        }
        let from = format!("{}/{file}", self.app_dir);
        let found = |(decl, values): (String, Vec<String>)| {
            Lookup::Found(Found {
                name: name.to_string(),
                decl,
                values,
            })
        };
        // The file as it was scanned, which is what the tree holds, whatever is on disk.
        let own = self
            .files
            .borrow_mut()
            .entry(from.clone())
            .or_insert_with(|| Some(Rc::new(crate::parse_cache::parse(src))))
            .clone();
        if prefix.is_none()
            && let Some(values) = own.as_deref().and_then(|m| constants(m, name))
        {
            return found((from, values));
        }
        let mut seen = HashSet::new();
        for import in extra::imports(src)
            .iter()
            .filter(|i| i.prefix.as_deref() == prefix)
        {
            let Some(path) = self.locate(&from, &import.uri) else {
                continue;
            };
            if let Some(decl) = self.declared_in(&path, name, &mut seen) {
                return found(decl);
            }
        }
        Lookup::Missing
    }

    /// The file at `path` or one of the files it exports (and theirs), whichever declares the enum.
    fn declared_in(
        &self,
        path: &str,
        name: &str,
        seen: &mut HashSet<String>,
    ) -> Option<(String, Vec<String>)> {
        if !seen.insert(path.to_string()) {
            return None;
        }
        let module = self.module(path)?;
        if let Some(values) = constants(&module, name) {
            return Some((path.to_string(), values));
        }
        module
            .exports
            .iter()
            .find_map(|uri| self.declared_in(&self.locate(path, uri)?, name, seen))
    }

    fn module(&self, path: &str) -> Option<Rc<Module>> {
        if let Some(m) = self.files.borrow().get(path) {
            return m.clone();
        }
        let src = self
            .root
            .as_ref()
            .and_then(|root| std::fs::read_to_string(root.join(path)).ok());
        let module = src
            .as_deref()
            .map(|src| Rc::new(crate::parse_cache::parse(src)));
        if self.root.is_some() {
            self.read.borrow_mut().push((path.to_string(), src));
        }
        self.files
            .borrow_mut()
            .insert(path.to_string(), module.clone());
        module
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
