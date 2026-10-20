//! Typed `extra`: how the generated file can name the type of a page's `extra`
//! parameter (`Product? extra`), so a typed route can take `extra: Product?`, and
//! whether the `extra` types of a guard, a layout and the routes below them agree.
//! Enum segments and query parameters (`enums.rs`) are named and imported the same way.
//!
//! The generated file doesn't import what page.dart imports, and the syntax tree
//! doesn't say which import a type comes from. So the type is found the way the
//! Dart compiler would, without reading the other files: a type declared in
//! page.dart is reached through page.dart's own import (`_i9.Local`); anything else is
//! imported from *each* of page.dart's imports with `show Name`, and Dart
//! ignores a `show` of a name the library doesn't export (a warning the
//! generated file silences). A prefixed type (`m.Product`) keeps its import,
//! under a prefix of its own.

use std::ops::Range;

use crate::dart;

/// One `import '...' [as prefix]` line of a Dart file.
#[derive(Debug, Clone, PartialEq)]
pub struct Import {
    pub uri: String,
    pub prefix: Option<String>,
    /// What the import lets through: `show`, `hide` (since 0.21.0).
    pub combinators: dart::Combinators,
}

/// The type of an `extra` parameter, ready for the generated file.
#[derive(Debug, Clone, PartialEq)]
pub struct ExtraType {
    /// The type as written in the file that declares it: `Product?`, `m.Product?`.
    pub source: String,
    /// The type as the generated file spells it: `Product?`, `_i9.Local?`, `_e2f5f6d82_m.Product?`.
    pub ty: String,
    /// Names to `show` from each of page.dart's unprefixed imports.
    pub shown: Vec<String>,
    /// `(prefix in page.dart, uri as written, alias in the generated file)`.
    pub aliased: Vec<(String, String, String)>,
    /// page.dart's unprefixed imports, as written.
    pub imports: Vec<String>,
    /// page.dart relative to the app folder: its relative imports resolve from there.
    pub file: String,
}

/// Names `dart:core` gives every file.
const CORE: [&str; 33] = [
    "String",
    "int",
    "double",
    "bool",
    "num",
    "Object",
    "List",
    "Map",
    "Set",
    "Iterable",
    "Uri",
    "DateTime",
    "Duration",
    "Future",
    "Stream",
    "Function",
    "Type",
    "Record",
    "Never",
    "Null",
    "BigInt",
    "RegExp",
    "Symbol",
    "Enum",
    "Comparable",
    "Exception",
    "Error",
    "StackTrace",
    "Iterator",
    "Pattern",
    "Match",
    "Sink",
    "Stopwatch",
];

/// Whether `dart:core` gives every file a type called `name`.
pub fn is_core(name: &str) -> bool {
    CORE.contains(&name)
}

/// The `import` lines of a Dart file.
pub fn imports(src: &str) -> Vec<Import> {
    let mut out = vec![];
    let mut rest = src;
    while let Some(at) = rest.find("import") {
        let before = &rest[..at];
        let line_start = before.rfind('\n').map_or(0, |i| i + 1);
        let at_line_start = before[line_start..].trim().is_empty();
        let after = &rest[at + "import".len()..];
        let Some(end) = after.find(';') else { break };
        let stmt = &after[..end];
        rest = &after[end..];
        if !at_line_start || !stmt.starts_with([' ', '\t', '\'', '"']) {
            continue;
        }
        let stmt = stmt.trim_start();
        let Some(q) = stmt.chars().next().filter(|c| matches!(c, '\'' | '"')) else {
            continue;
        };
        let Some(close) = stmt[1..].find(q) else {
            continue;
        };
        let uri = stmt[1..=close].to_string();
        let tail = &stmt[close + 2..];
        let words: Vec<&str> = tail
            .split(|c: char| c.is_whitespace() || c == ',')
            .filter(|t| !t.is_empty())
            .collect();
        let prefix = words
            .iter()
            .position(|t| *t == "as")
            .and_then(|i| words.get(i + 1))
            .map(std::string::ToString::to_string);
        out.push(Import {
            uri,
            prefix,
            combinators: dart::Combinators::parse(tail),
        });
    }
    out
}

/// Whether the file declares a type called `name` (`class`, `enum`, `typedef`, `mixin`
/// or `extension type`).
pub fn declares(src: &str, name: &str) -> bool {
    const MODIFIERS: [&str; 8] = [
        "abstract",
        "base",
        "final",
        "sealed",
        "interface",
        "mixin",
        "augment",
        "extension",
    ];
    src.lines().any(|line| {
        let line = line.trim_start();
        if line.starts_with("//") {
            return false;
        }
        let tokens: Vec<&str> = line
            .split(|c: char| !(c.is_alphanumeric() || c == '_' || c == '$'))
            .filter(|t| !t.is_empty())
            .collect();
        tokens.iter().enumerate().any(|(i, t)| {
            matches!(*t, "class" | "enum" | "typedef" | "mixin" | "type")
                && tokens.get(i + 1) == Some(&name)
                && tokens[..i]
                    .iter()
                    .all(|m| MODIFIERS.contains(m) || *m == "class")
        })
    })
}

/// Whether an `extra` of this type takes whatever comes: `Object?`, `Object` or `dynamic`.
/// (Nothing has to be nullable to be one; a non-nullable `extra` is an error elsewhere.)
pub fn takes_any(ty: &str) -> bool {
    matches!(ty.trim_end_matches('?'), "Object" | "dynamic")
}

/// Whether an `extra` parameter of a guard or layout can read what a route's own `extra`
/// (a page's or a redirect's) holds: the same type (nullability aside), or `Object?`, which
/// reads anything. A guard for `Product?` under a route for `Object?` would silently miss
/// what isn't a `Product`, so it isn't one.
pub fn fits(reader: &str, route: &str) -> bool {
    takes_any(reader) || reader.trim_end_matches('?') == route.trim_end_matches('?')
}

/// Whether two guards and layouts above a route that takes no `extra` of its own can read
/// the same object: the same type, or one of them takes anything.
pub fn agree(a: &str, b: &str) -> bool {
    takes_any(a) || takes_any(b) || a.trim_end_matches('?') == b.trim_end_matches('?')
}

/// A type name inside a type: `Product` or `m.Product`.
pub(crate) struct TypeRef {
    pub(crate) prefix: Option<String>,
    pub(crate) name: String,
    pub(crate) at: Range<usize>,
}

fn is_ident(c: char) -> bool {
    c.is_alphanumeric() || c == '_' || c == '$'
}

/// The type names in `ty`, skipping record field names and `dart:core` types.
pub(crate) fn type_refs(ty: &str) -> Vec<TypeRef> {
    let chars: Vec<(usize, char)> = ty.char_indices().collect();
    let mut out = vec![];
    let mut i = 0;
    let word = |from: usize| {
        let mut j = from;
        while j < chars.len() && is_ident(chars[j].1) {
            j += 1;
        }
        j
    };
    while i < chars.len() {
        if !is_ident(chars[i].1) {
            i += 1;
            continue;
        }
        let end = word(i);
        let first: String = chars[i..end].iter().map(|(_, c)| c).collect();
        let bytes_end = |j: usize| chars.get(j).map_or(ty.len(), |(b, _)| *b);
        if end < chars.len()
            && chars[end].1 == '.'
            && end + 1 < chars.len()
            && is_ident(chars[end + 1].1)
        {
            let end2 = word(end + 1);
            let name: String = chars[end + 1..end2].iter().map(|(_, c)| c).collect();
            out.push(TypeRef {
                prefix: Some(first),
                name,
                at: chars[i].0..bytes_end(end2),
            });
            i = end2;
            continue;
        }
        let is_type =
            first.starts_with(|c: char| c.is_uppercase()) && !CORE.contains(&first.as_str());
        if is_type {
            out.push(TypeRef {
                prefix: None,
                name: first,
                at: chars[i].0..bytes_end(end),
            });
        }
        i = end;
    }
    out
}

/// `ty` without the import prefixes of its types: `List<m.Category>?` is `List<Category>?`.
pub fn unprefixed(ty: &str) -> String {
    let mut out = String::new();
    let mut last = 0;
    for r in type_refs(ty) {
        out.push_str(&ty[last..r.at.start]);
        out.push_str(&r.name);
        last = r.at.end;
    }
    out.push_str(&ty[last..]);
    out
}

/// The library an import names, the same wherever it is spelled (since 0.20.0). A `dart:` or
/// `package:` URI is as written; a relative one is resolved against the folder of `file` (the file
/// that wrote it, relative to the app folder) and normalized, so `../m.dart` in `a/page.dart` and
/// `../../m.dart` in `a/b/page.dart` are both `m.dart`, and a library outside the app folder keeps
/// its leading `..` (`../models/category.dart`). It is resolved the way `Config::import_from_file`
/// resolves it, without a config: the app folder is the root.
pub fn library_of(file: &str, uri: &str) -> String {
    if uri.contains(':') {
        return uri.to_string();
    }
    let mut parts: Vec<&str> = vec![];
    let folder = file.rsplit_once('/').map_or("", |(dir, _)| dir);
    for seg in folder.split('/').chain(uri.split('/')) {
        match seg {
            "" | "." => {}
            ".." if parts.last().is_some_and(|last| *last != "..") => {
                parts.pop();
            }
            s => parts.push(s),
        }
    }
    parts.join("/")
}

/// The tag of the import alias of a prefixed type from [library] (see [`library_of`]), since
/// 0.20.0: 8 hex digits of a hash of the library. The alias follows the library the prefix names,
/// never the file that happened to spell the type (the first file that constrains a segment, say,
/// which another file can become), so it is the same for every file that imports that library
/// under that prefix, and differs for another library under the same prefix.
pub fn alias_tag(library: &str) -> String {
    crate::reload::short_hash(library)
}

/// Works out the generated spelling of `ty`, the type of `extra` in `src` (the
/// source of the page, layout, guard or redirect at `file`, whose import in the generated
/// file is `_i{import}`). A prefixed type's alias is `_e<alias_tag(library)>_<prefix>` (since
/// 0.20.0: it names the library the prefix imports, not the file or the route's position).
pub fn extra_type(ty: &str, src: &str, file: &str, import: usize) -> ExtraType {
    let all = imports(src);
    let mut spelled = String::new();
    let mut last = 0;
    let (mut shown, mut aliased): (Vec<String>, Vec<(String, String, String)>) = (vec![], vec![]);
    for r in type_refs(ty) {
        spelled.push_str(&ty[last..r.at.start]);
        last = r.at.end;
        match &r.prefix {
            Some(p) => match all.iter().find(|i| i.prefix.as_deref() == Some(p)) {
                Some(i) => {
                    let alias = format!("_e{}_{p}", alias_tag(&library_of(file, &i.uri)));
                    if !aliased.iter().any(|(q, ..)| q == p) {
                        aliased.push((p.clone(), i.uri.clone(), alias.clone()));
                    }
                    spelled.push_str(&format!("{alias}.{}", r.name));
                }
                None => spelled.push_str(&ty[r.at.clone()]),
            },
            None if declares(src, &r.name) => spelled.push_str(&format!("_i{import}.{}", r.name)),
            None => {
                if !shown.contains(&r.name) {
                    shown.push(r.name.clone());
                }
                spelled.push_str(&r.name);
            }
        }
    }
    spelled.push_str(&ty[last..]);
    ExtraType {
        source: ty.to_string(),
        ty: spelled,
        shown,
        aliased,
        imports: all
            .into_iter()
            .filter(|i| i.prefix.is_none())
            .map(|i| i.uri)
            .collect(),
        file: file.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SRC: &str = "import 'package:flutter/material.dart';\nimport '../../models.dart' show Product;\nimport \"x.dart\" as m;\nimport 'dart:async'\n    hide Timer;\n// import 'nope.dart';\n\nenum Mode { a }\nabstract class Local {}\nclass Page {}\n";

    #[test]
    fn reads_imports() {
        let i = imports(SRC);
        let uris: Vec<&str> = i.iter().map(|i| i.uri.as_str()).collect();
        assert_eq!(
            uris,
            [
                "package:flutter/material.dart",
                "../../models.dart",
                "x.dart",
                "dart:async"
            ]
        );
        assert_eq!(i[2].prefix.as_deref(), Some("m"));
        assert_eq!(i[1].prefix, None);
    }

    #[test]
    fn imports_keep_their_combinators() {
        let i = imports(
            "import 'a.dart' as m show A, B hide C;\nimport 'b.dart' show B;\nimport 'c.dart' hide D;\n",
        );
        assert_eq!(i[0].prefix.as_deref(), Some("m"));
        assert!(i[0].combinators.admits("A") && !i[0].combinators.admits("D"));
        assert!(!i[0].combinators.admits("C") && !i[0].combinators.admits("Z"));
        assert_eq!(i[1].combinators.show, Some(vec!["B".to_string()]));
        assert!(!i[2].combinators.admits("D"));
    }

    #[test]
    fn finds_declared_types() {
        assert!(declares(SRC, "Mode"));
        assert!(declares(SRC, "Local"));
        assert!(!declares(SRC, "Product"));
        assert!(!declares(SRC, "nope"));
    }

    #[test]
    fn takes_import_prefixes_off_types() {
        assert_eq!(unprefixed("List<m.Category>?"), "List<Category>?");
        assert_eq!(unprefixed("Map<a.K, b.V>"), "Map<K, V>");
        assert_eq!(unprefixed("Sort?"), "Sort?");
        assert_eq!(
            unprefixed("({int id, m.Product p})"),
            "({int id, Product p})"
        );
    }

    #[test]
    fn spells_types_for_the_generated_file() {
        let t = extra_type("Map<String, Product>?", SRC, "a/page.dart", 4);
        assert_eq!(t.ty, "Map<String, Product>?");
        assert_eq!(t.shown, ["Product"]);
        let t = extra_type("Local?", SRC, "a/page.dart", 4);
        assert_eq!(t.ty, "_i4.Local?");
        assert!(t.shown.is_empty());
        let t = extra_type("List<m.Thing>?", SRC, "a/page.dart", 4);
        // `x.dart` next to `a/page.dart` is the library `a/x.dart`.
        assert_eq!(t.ty, "List<_e6bc4e6b5_m.Thing>?");
        assert_eq!(
            t.aliased,
            [(
                "m".to_string(),
                "x.dart".to_string(),
                "_e6bc4e6b5_m".to_string()
            )]
        );
        let t = extra_type("({int id, Product p})?", SRC, "a/page.dart", 4);
        assert_eq!(t.ty, "({int id, Product p})?");
        assert_eq!(t.shown, ["Product"]);
        let t = extra_type("String?", SRC, "a/page.dart", 4);
        assert!(t.shown.is_empty());
    }

    #[test]
    fn a_library_is_the_same_wherever_it_is_spelled() {
        // Relative to the app folder, `..` resolved against the folder of the file that wrote it.
        assert_eq!(library_of("a/page.dart", "x.dart"), "a/x.dart");
        assert_eq!(library_of("a/page.dart", "./x.dart"), "a/x.dart");
        assert_eq!(library_of("a/b/page.dart", "../x.dart"), "a/x.dart");
        assert_eq!(library_of("a/b/page.dart", "../../m.dart"), "m.dart");
        assert_eq!(library_of("page.dart", "m.dart"), "m.dart");
        assert_eq!(library_of("a/page.dart", "../m.dart"), "m.dart");
        // A library outside the app folder keeps its `..`, from any depth.
        assert_eq!(
            library_of("shop/page.dart", "../../models/category.dart"),
            "../models/category.dart"
        );
        assert_eq!(
            library_of("shop/$c/b/page.dart", "../../../../models/category.dart"),
            "../models/category.dart"
        );
        // `dart:` and `package:` are as written.
        assert_eq!(
            library_of("a/b/page.dart", "package:x/y.dart"),
            "package:x/y.dart"
        );
        assert_eq!(library_of("a/page.dart", "dart:async"), "dart:async");
    }

    #[test]
    fn an_alias_names_the_library_not_the_file() {
        assert_eq!(alias_tag("a/x.dart"), "6bc4e6b5");
        let alias = |file: &str, src: &str| extra_type("m.Thing", src, file, 4).ty;
        let same = alias("a/page.dart", "import '../x.dart' as m;");
        // Another file, another folder, the same library under the same prefix: one alias.
        assert_eq!(same, alias("x/page.dart", "import '../x.dart' as m;"));
        assert_eq!(same, alias("a/b/page.dart", "import '../../x.dart' as m;"));
        assert_eq!(same, alias("page.dart", "import 'x.dart' as m;"));
        assert_eq!(same, format!("_e{}_m.Thing", alias_tag("x.dart")));
        // Another library under the same prefix: another alias, so two imports of `m` never clash.
        assert_ne!(same, alias("a/page.dart", "import '../y.dart' as m;"));
        assert_ne!(same, alias("a/page.dart", "import 'x.dart' as m;"));
        assert_ne!(
            alias("a/page.dart", "import 'package:p/x.dart' as m;"),
            alias("a/page.dart", "import 'package:q/x.dart' as m;")
        );
        // The same library under another prefix: another alias too.
        let other = extra_type("n.Thing", "import '../x.dart' as n;", "a/page.dart", 4).ty;
        assert_eq!(other, format!("_e{}_n.Thing", alias_tag("x.dart")));
    }
}
