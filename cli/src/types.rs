//! Types compared by what they name, not by how they are spelled (since 0.21.0).
//!
//! The generator reads a syntax tree. Two spellings of a type (`ProductView` and the `Product` its
//! typedef names, `m.Product` and `Product`) are one type when, with every typedef followed and every
//! import prefix resolved, they come to the same declarations. Only this package's files, and since
//! 0.22.0 those of its `path:` dependencies, are read (through `enums::Libs`): a typedef of another
//! package (hosted, `git:`, the SDK's), a generic typedef, one in a `part` file are not followed,
//! and their names are compared as spelled. Callers compare spellings first and
//! ask for the canonical form only when they differ, or when no spelling bound a parameter at all,
//! so what matched before matches the same way.

use crate::extra;

/// What a type name names, found by a [`Scope`].
#[derive(Debug, Clone, PartialEq)]
pub struct Declared {
    /// The file that declares it, relative to the project: `lib/models/ids.dart`; a path
    /// dependency's by its package URI, `package:shared/src/ids.dart` (since 0.22.0).
    pub decl: String,
    pub name: String,
    /// For a `typedef X = T;` (not generic): `T` as written in `decl`.
    pub alias: Option<String>,
}

/// Looks a type name up as the file `path` (relative to the project) sees it.
pub trait Scope {
    fn declared(&self, path: &str, prefix: Option<&str>, name: &str) -> Option<Declared>;
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Canonical {
    /// Each name replaced by what it names: a typedef by its own canonical `key`, a type declared
    /// in a file fsp reads by `<decl>#<Name>`, anything else as spelled, its import prefix included
    /// (two packages' `User` are two types). Equal keys, one type.
    pub key: String,
    /// The typedefs followed, prefixes dropped, every name bare: `Map<String, Product>`.
    pub expanded: String,
    /// Names neither `dart:core` nor declared in the files fsp reads, in order, once each.
    pub unknown: Vec<String>,
    /// A name this package declares (a class, an enum, a mixin) is left in it.
    pub declared: bool,
    /// At least one typedef was followed.
    pub followed: bool,
}

/// How many typedefs one type may chain through; a cycle (`A = B`, `B = A`) stops here.
const DEPTH: usize = 8;

/// The canonical form of `text`, as written in the file `path` (relative to the project).
pub fn canonical(scope: &dyn Scope, path: &str, text: &str) -> Canonical {
    let mut c = canonical_at(scope, path, text, 0);
    c.key = c.key.replace("??", "?");
    c.expanded = c.expanded.replace("??", "?");
    c
}

fn canonical_at(scope: &dyn Scope, path: &str, text: &str, depth: usize) -> Canonical {
    let mut out = Canonical::default();
    let mut last = 0;
    for r in extra::type_refs(text) {
        let between = &text[last..r.at.start];
        out.key.push_str(between);
        out.expanded.push_str(between);
        last = r.at.end;
        let Some(d) = scope.declared(path, r.prefix.as_deref(), &r.name) else {
            // Not followed, so compared as spelled, prefix included: `api.User` and `db.User` are the
            // classes of two other packages, and are not one type.
            if let Some(prefix) = &r.prefix {
                out.key.push_str(prefix);
                out.key.push('.');
            }
            out.key.push_str(&r.name);
            out.expanded.push_str(&r.name);
            push_unknown(&mut out.unknown, r.name);
            continue;
        };
        match d.alias {
            Some(alias) if depth < DEPTH => {
                let inner = canonical_at(scope, &d.decl, &alias, depth + 1);
                out.key.push_str(&inner.key);
                out.expanded.push_str(&inner.expanded);
                for name in inner.unknown {
                    push_unknown(&mut out.unknown, name);
                }
                out.declared |= inner.declared;
                out.followed = true;
            }
            _ => {
                out.key.push_str(&format!("{}#{}", d.decl, d.name));
                out.expanded.push_str(&d.name);
                out.declared = true;
            }
        }
    }
    let rest = &text[last..];
    out.key.push_str(rest);
    out.expanded.push_str(rest);
    out
}

fn push_unknown(unknown: &mut Vec<String>, name: String) {
    if !unknown.contains(&name) {
        unknown.push(name);
    }
}

/// The names one side leaves unfollowed and the other does not: what makes two types that are not
/// one, when a typedef of the app's files could not be followed. Names both sides leave unfollowed
/// are not the cause and are left out.
pub fn unfollowed(a: &Canonical, b: &Canonical) -> Vec<String> {
    let mut names = vec![];
    for name in a.unknown.iter().chain(&b.unknown) {
        if !(a.unknown.contains(name) && b.unknown.contains(name)) {
            push_unknown(&mut names, name.clone());
        }
    }
    names
}

/// What a message about two types that are not the same adds when a name either side spells could
/// not be followed (since 0.21.0); empty when there is none.
pub fn hint(a: &Canonical, b: &Canonical) -> String {
    hint_of(&unfollowed(a, b))
}

/// The hint for `names`, the names that could not be followed; empty for none.
pub fn hint_of(names: &[String]) -> String {
    let quoted: Vec<String> = names.iter().map(|n| format!("`{n}`")).collect();
    match quoted.as_slice() {
        [] => String::new(),
        [one] => format!(
            "; fsp follows typedefs only in the files of this package and of its path dependencies, and found no declaration of {one} there, so it compares it as spelled"
        ),
        [init @ .., last] => format!(
            "; fsp follows typedefs only in the files of this package and of its path dependencies, and found no declaration of {} or {last} there, so it compares them as spelled",
            init.join(", ")
        ),
    }
}
