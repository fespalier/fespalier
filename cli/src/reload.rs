//! What a hot reload compares in a generated `app.g.dart` (since 0.19.0).
//!
//! The template gives the file two const slots (`AppRoutes._version` and `AppRoutes._kept`, see
//! `app.g.dart.jinja`). A hot reload re-reads consts, so the running code and the reloaded code
//! can each say which version they are and what they keep:
//!
//! - `_version` is a hash of the whole file. Equal versions mean nothing changed, so a hot reload
//!   swaps nothing and a page edit costs nothing.
//! - `_kept` has one hash for each top-level `final` and each `static final` of the file, the
//!   fields a hot reload keeps the first value of, plus `'(router)'`, the settings of the router.
//!   A hot reload refuses a swap when a name in both maps has another hash: the old value is still
//!   the one in use. Added or removed names are fine.
//!
//! The fields are read from the raw template output, line by line, so the file is never parsed as
//! Dart (a `dart format` of it would not change a hash: nothing here is formatted).
//!
//! `fsp dev` reads the two slots back from the file (`read_stamp`) and asks whether a hot reload
//! would swap the routes (`Stamp::swaps_to`), which is `RoutesReload`'s rule (since 0.19.0).

use std::collections::BTreeMap;
use std::fmt::Write as _;

use sha2::{Digest, Sha256};

use crate::emit::dart_str;

/// Fills the two const slots of a rendered `app.g.dart`: `{/*kept*/}` with one hash for each kept
/// field and for `router`, and then `'/*version*/'` with a hash of the code so far. The same input
/// gives the same bytes. `imports` is the import path of each `_i<n>` prefix, so that an import's
/// number moving (a folder inserted before it) keeps the hashes of what it names.
pub fn stamp(code: &str, imports: &[String], router: &str) -> String {
    let mut kept: BTreeMap<String, String> = kept_fields(code, imports)
        .into_iter()
        .map(|(name, declaration)| (name, short_hash(&declaration)))
        .collect();
    kept.insert("(router)".to_string(), short_hash(router));
    let mut map = String::from("{\n");
    for (name, hash) in &kept {
        let _ = writeln!(map, "    {}: {},", dart_str(name), dart_str(hash));
    }
    map.push_str("  }");
    let filled = code.replacen("{/*kept*/}", &map, 1);
    let version = format!("'{}'", long_hash(&filled));
    filled.replacen("'/*version*/'", &version, 1)
}

/// The top-level and static `final` fields of the generated [code], as (name, normalized
/// declaration), in file order. A name is `field` at the top level and `Class.field` in a class.
/// The `_i<n>` prefixes of [imports] are replaced by their paths, and whitespace is collapsed.
pub(crate) fn kept_fields(code: &str, imports: &[String]) -> Vec<(String, String)> {
    let lines: Vec<&str> = code.lines().collect();
    let mut out = Vec::new();
    let mut class: Option<String> = None;
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        i += 1;
        if line == "}" {
            class = None;
            continue;
        }
        if !line.starts_with(' ') {
            if let Some(name) = class_name(line) {
                class = Some(name);
                continue;
            }
            if !(line.starts_with("final ") || line.starts_with("late final ")) {
                continue;
            }
            let Some(name) = declared_name(line) else {
                continue;
            };
            let end = declaration_end(&lines, i - 1);
            out.push((name, normalize(&lines[i - 1..=end], imports)));
            i = end + 1;
            continue;
        }
        let Some(owner) = class.clone() else {
            continue;
        };
        let Some(rest) = line.strip_prefix("  ") else {
            continue;
        };
        if rest.starts_with(' ') {
            continue;
        }
        if !(rest.starts_with("static final ") || rest.starts_with("static late final ")) {
            continue;
        }
        let Some(name) = declared_name(line) else {
            continue;
        };
        let end = declaration_end(&lines, i - 1);
        out.push((
            format!("{owner}.{name}"),
            normalize(&lines[i - 1..=end], imports),
        ));
        i = end + 1;
    }
    out
}

/// The type a line at the top level opens, or `None`: a class (`abstract final class AppRoutes {`),
/// an enum, a mixin (`mixin M on X {`, `base mixin class M {`), an extension (`extension Name on T {`)
/// or an extension type (`extension type const Id(int v) {`). Only the words of a header count: a
/// field named `enumValue` is not an `enum`. An extension with no name is named by its header
/// (`extension on List<int>`), so that two of them in a file keep apart.
fn class_name(line: &str) -> Option<String> {
    let words: Vec<&str> = line.split_whitespace().collect();
    let skip = words
        .iter()
        .take_while(|w| matches!(**w, "abstract" | "base" | "final" | "sealed" | "interface"))
        .count();
    let word = |n: usize| words.get(skip + n).copied();
    match word(0)? {
        "class" | "enum" => identifier(word(1)?),
        "mixin" => identifier(if word(1) == Some("class") {
            word(2)?
        } else {
            word(1)?
        }),
        "extension" if skip == 0 => match word(1)? {
            "type" => identifier(if word(2) == Some("const") {
                word(3)?
            } else {
                word(2)?
            }),
            "on" => Some(unnamed_extension(line)),
            name => identifier(name),
        },
        generic if skip == 0 && generic.starts_with("extension<") => Some(unnamed_extension(line)),
        _ => None,
    }
}

/// The leading identifier of [word] (`Id(int` is `Id`, `StringX<T>` is `StringX`), or `None`.
fn identifier(word: &str) -> Option<String> {
    let name: String = word.chars().take_while(|c| is_identifier(*c)).collect();
    (!name.is_empty()).then_some(name)
}

/// The header of an extension with no name, up to its `{`, whitespace collapsed.
fn unnamed_extension(line: &str) -> String {
    line.split('{')
        .next()
        .unwrap_or(line)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// The name a declaration's first line declares: the last word before its ` = `.
fn declared_name(line: &str) -> Option<String> {
    let before = line.split(" = ").next()?;
    if before == line {
        return None;
    }
    before.split_whitespace().last().map(str::to_string)
}

/// The index of the line a declaration starting at `start` ends on. It ends on its first line if
/// that line ends with `;`; else on the next line with the same indentation that ends with `;`.
/// A line with less indentation, or the end of the file, ends it there.
fn declaration_end(lines: &[&str], start: usize) -> usize {
    let indent = indentation(lines[start]);
    if lines[start].trim_end().ends_with(';') {
        return start;
    }
    for (offset, line) in lines.iter().enumerate().skip(start + 1) {
        let here = indentation(line);
        if here < indent {
            return offset - 1;
        }
        if here == indent && line.trim_end().ends_with(';') {
            return offset;
        }
    }
    lines.len() - 1
}

fn indentation(line: &str) -> usize {
    line.len() - line.trim_start().len()
}

/// [lines] joined, with whitespace collapsed and each `_i<n>` prefix (not part of a longer name,
/// and not followed by a digit) replaced by `imports[n]`.
fn normalize(lines: &[&str], imports: &[String]) -> String {
    let joined = lines
        .iter()
        .flat_map(|l| l.split_whitespace())
        .collect::<Vec<_>>()
        .join(" ");
    let chars: Vec<char> = joined.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '_'
            && chars.get(i + 1) == Some(&'i')
            && (i == 0 || !is_identifier(chars[i - 1]))
        {
            let mut end = i + 2;
            while end < chars.len() && chars[end].is_ascii_digit() {
                end += 1;
            }
            if end > i + 2 {
                let number: String = chars[i + 2..end].iter().collect();
                if let Some(path) = number.parse::<usize>().ok().and_then(|n| imports.get(n)) {
                    out.push_str(path);
                    i = end;
                    continue;
                }
            }
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

fn is_identifier(c: char) -> bool {
    c.is_alphanumeric() || c == '_' || c == '$'
}

/// The first 8 hex digits of the SHA-256 of [text]. Also the suffix of a folder's stem when another
/// folder that owns names has the same one, and the tag of an import alias (since 0.20.0).
pub(crate) fn short_hash(text: &str) -> String {
    hex(text)[..8].to_string()
}

/// The first 16 hex digits of the SHA-256 of [text].
fn long_hash(text: &str) -> String {
    hex(text)[..16].to_string()
}

fn hex(text: &str) -> String {
    Sha256::digest(text.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// The two slots of a generated file, as the file holds them (since 0.19.0): `fsp dev` keeps one
/// for the routes the running app holds and one for the file on disk, and asks
/// [`Stamp::swaps_to`] whether a hot reload would swap them in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Stamp {
    /// The file's `_version`: 16 hex digits, a hash of the whole file.
    pub version: String,
    /// The file's `_kept`: each kept name with its 8 hex digits.
    pub kept: BTreeMap<String, String>,
}

impl Stamp {
    /// Whether a hot reload from the routes of `self` to those of `next` swaps them in: no name
    /// both keep has another hash, and added or removed names do not count. This is the rule of
    /// `RoutesReload._reassembled` in `routes_reload.dart`, so the two must stay equal.
    #[must_use]
    pub fn swaps_to(&self, next: &Stamp) -> bool {
        self.kept
            .iter()
            .all(|(name, hash)| next.kept.get(name).is_none_or(|other| other == hash))
    }
}

/// The stamp of a generated file's text, formatted or not, as [`stamp`] wrote it (since 0.19.0):
/// the literal of `_version`, and the name and hash pairs of `_kept`. `None` unless the version is
/// 16 hex digits and every hash is 8, and `_kept` has at least one pair, so that a file that was
/// never stamped, or that was edited by hand, makes `fsp dev` restart.
#[must_use]
pub fn read_stamp(text: &str) -> Option<Stamp> {
    let declaration = &text[text.find("String _version =")?..];
    let declaration = &declaration[..declaration.find(';')?];
    let versions = string_literals(declaration);
    let [version] = versions.as_slice() else {
        return None;
    };
    if !is_hex(version, 16) {
        return None;
    }
    let map = &text[text.find("Map<String, String> _kept =")?..];
    let open = map.find('{')?;
    let close = open + map[open..].find('}')?;
    let literals = string_literals(&map[open + 1..close]);
    if !literals.len().is_multiple_of(2) {
        return None;
    }
    let mut kept = BTreeMap::new();
    for pair in literals.chunks(2) {
        let [name, hash] = pair else {
            return None;
        };
        if !is_hex(hash, 8) || kept.insert(name.clone(), hash.clone()).is_some() {
            return None;
        }
    }
    (!kept.is_empty()).then(|| Stamp {
        version: version.clone(),
        kept,
    })
}

/// Whether [text] is exactly [digits] lowercase hex digits (`'0'..='9'` and `'a'..='f'`).
fn is_hex(text: &str, digits: usize) -> bool {
    text.len() == digits && text.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// The single-quoted literals of [text], in order, without their quotes. A backslash makes the
/// character after it stand for itself, which undoes `emit::dart_str`'s escapes (`\'`, `\\`, `\$`).
fn string_literals(text: &str) -> Vec<String> {
    let mut out = vec![];
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c != '\'' {
            continue;
        }
        let mut literal = String::new();
        while let Some(c) = chars.next() {
            match c {
                '\'' => break,
                '\\' => literal.extend(chars.next()),
                _ => literal.push(c),
            }
        }
        out.push(literal);
    }
    out
}
