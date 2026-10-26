//! Edits of an app's `pubspec.yaml` that keep the rest of it byte for byte (since 0.23.0): its
//! comments, blank lines, key order, quotes and line endings. `fsp add` and `fsp upgrade --app`
//! write through it.
//!
//! It is a line editor for the block YAML a pubspec is written in, not a YAML library: it finds a
//! key by its indentation, inserts whole lines, and replaces one scalar where it stands. After each
//! edit the text is read back with `serde_yaml_ng` and compared with what the edit means (the
//! document before it, with that one change made to its value). A difference, or a layout it does
//! not edit (a flow mapping where lines would go in, a key on no line of its own), is an
//! [`EditError`] that names the edit, and the text is left as it was: the caller writes nothing and
//! prints the change for a person to make ([`Edit::by_hand`]). So an edit never changes more than
//! it says. The edited files are written together, or none is ([`write_files`], since 0.24.1).

use std::path::Path;

use serde_yaml_ng::{Mapping, Value};

/// One file [`write_files`] writes: where it is, its text as it was read, and its new text.
pub struct Rewrite<'a> {
    pub path: &'a Path,
    pub before: &'a str,
    pub after: &'a str,
}

/// Writes `files` in their order with `write` (`std::fs::write` outside the tests). When one cannot
/// be written, those written before it are written back as they were read, so a failed write leaves
/// every file as it was, and the error says which one failed and that nothing was written (since
/// 0.24.1). `fsp add` and `fsp upgrade --app` give `pubspec_overrides.yaml` first, then
/// `pubspec.yaml`.
pub fn write_files(
    files: &[Rewrite],
    write: &mut dyn FnMut(&Path, &str) -> std::io::Result<()>,
) -> Result<(), String> {
    for (i, file) in files.iter().enumerate() {
        let Err(e) = write(file.path, file.after) else {
            continue;
        };
        let failed = format!("writing {}: {e}", file.path.display());
        let written = &files[..i];
        if written.is_empty() {
            return Err(format!("{failed}; nothing was written"));
        }
        let names: Vec<String> = written
            .iter()
            .map(|w| w.path.display().to_string())
            .collect();
        let stuck: Vec<String> = written
            .iter()
            .filter_map(|w| {
                write(w.path, w.before)
                    .err()
                    .map(|e| format!("{} ({e})", w.path.display()))
            })
            .collect();
        return Err(if stuck.is_empty() {
            format!(
                "{failed}; {} {} put back as {} read, so nothing was written",
                names.join(" and "),
                if names.len() == 1 { "was" } else { "were" },
                if names.len() == 1 {
                    "it was"
                } else {
                    "they were"
                },
            )
        } else {
            format!(
                "{failed}; and {} could not be put back as read, so it has the new text: put it back by hand (`git checkout` it, or undo the change fsp printed)",
                stuck.join(" and ")
            )
        });
    }
    Ok(())
}

/// Where an inserted key goes among the keys already in its mapping.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Place {
    /// After the last one.
    End,
    /// In name order when the keys are in name order, else after the last one. A key whose value
    /// has `sdk:` under it (`flutter: {sdk: flutter}`) is left out of the comparison: pubspecs put
    /// the SDK's packages first or last.
    Sorted,
}

/// The value an inserted key is given.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Body {
    /// `key: <this>` on the key's line, as YAML (`"^1.5.0"`, `true`, `[/x]`).
    Inline(String),
    /// The lines under `key:`, indented two spaces per level from none (`git:`, `  url: ...`); they
    /// are indented the way the file is. Comment lines may be among them. Empty is `key:` alone.
    Block(Vec<String>),
}

/// One change to a pubspec. A path names mapping keys from the top (`dependencies`, `fespalier`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Edit {
    /// The scalar at `path`, which is there, becomes `value` (as YAML: `v0.23.0`, `true`). Its
    /// quotes and the comment after it are kept.
    Set { path: Vec<String>, value: String },
    /// `key` is added to the mapping at `parent`, with `comments` (each a whole `# ...`) above it.
    /// A parent that is not there is made, as nested keys, inside the nearest one that is.
    Insert {
        parent: Vec<String>,
        key: String,
        body: Body,
        comments: Vec<String>,
        place: Place,
    },
    /// `item` is added at the end of the sequence at `path`: inside its brackets when it is `[a, b]`,
    /// as a `- item` line when it is a block sequence, and as `key: [item]` when there is none.
    /// `comment` goes on a line above the key (a flow sequence) or above the item (a block one).
    Append {
        path: Vec<String>,
        item: String,
        comment: Option<String>,
    },
}

/// The mapping at `path`, as a message names it: `` `dependencies:` ``, or the top level.
fn mapping_name(path: &[String]) -> String {
    if path.is_empty() {
        "the top level of the file".to_string()
    } else {
        format!("`{}`", shown(path))
    }
}

/// The path as a person reads it in the file: `dependencies: fespalier: git: ref:`.
fn shown(path: &[String]) -> String {
    path.iter()
        .map(|p| format!("{p}:"))
        .collect::<Vec<_>>()
        .join(" ")
}

fn owned(path: &[&str]) -> Vec<String> {
    path.iter().map(|p| (*p).to_string()).collect()
}

impl Edit {
    #[must_use]
    pub fn set(path: &[&str], value: &str) -> Edit {
        Edit::Set {
            path: owned(path),
            value: value.to_string(),
        }
    }

    #[must_use]
    pub fn insert(parent: &[&str], key: &str, body: Body, place: Place) -> Edit {
        Edit::Insert {
            parent: owned(parent),
            key: key.to_string(),
            body,
            comments: vec![],
            place,
        }
    }

    #[must_use]
    pub fn append(path: &[&str], item: &str, comment: Option<String>) -> Edit {
        Edit::Append {
            path: owned(path),
            item: item.to_string(),
            comment,
        }
    }

    /// The same edit with `comments` above the inserted key (an `Insert` only).
    #[must_use]
    pub fn with_comments(mut self, lines: Vec<String>) -> Edit {
        if let Edit::Insert { comments, .. } = &mut self {
            *comments = lines;
        }
        self
    }

    /// The change as a person makes it, for when the editor cannot: what to write where.
    #[must_use]
    pub fn by_hand(&self) -> String {
        match self {
            Edit::Set { path, value } => format!("set `{}` to `{value}`", shown(path)),
            Edit::Insert {
                parent,
                key,
                body,
                comments,
                ..
            } => {
                let place = if parent.is_empty() {
                    "at the top level".to_string()
                } else {
                    format!("under `{}`", shown(parent))
                };
                let mut out = format!("{place} add:");
                for line in comments {
                    out.push_str(&format!("\n    {line}"));
                }
                match body {
                    Body::Inline(value) => out.push_str(&format!("\n    {key}: {value}")),
                    Body::Block(lines) => {
                        out.push_str(&format!("\n    {key}:"));
                        for line in lines {
                            out.push_str(&format!("\n      {line}"));
                        }
                    }
                }
                out
            }
            Edit::Append { path, item, .. } => {
                format!("add `{item}` to the list `{}`", shown(path))
            }
        }
    }
}

/// An edit the editor did not make, and why. The text is as it was before it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EditError {
    pub edit: Box<Edit>,
    pub why: String,
}

impl std::fmt::Display for EditError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.why)
    }
}

impl std::error::Error for EditError {}

/// `text` with `edits` made, in order: each one checked against what it means before the next.
pub fn apply(text: &str, edits: &[Edit]) -> Result<String, EditError> {
    let Some(first) = edits.first() else {
        return Ok(text.to_string());
    };
    let mut doc = Doc::parse(text);
    let mut expected: Value = serde_yaml_ng::from_str(text).map_err(|e| EditError {
        edit: Box::new(first.clone()),
        why: format!("pubspec.yaml is not valid YAML: {e}"),
    })?;
    for edit in edits {
        let fail = |why: String| EditError {
            edit: Box::new(edit.clone()),
            why,
        };
        let mut want = expected.clone();
        apply_to_value(&mut want, edit).map_err(fail)?;
        doc.edit(edit).map_err(fail)?;
        let got: Option<Value> = serde_yaml_ng::from_str(&doc.text()).ok();
        if got.as_ref() != Some(&want) {
            return Err(fail(format!(
                "`{}` is laid out in a way fsp does not edit",
                shown(target_of(edit))
            )));
        }
        expected = want;
    }
    Ok(doc.text())
}

/// The path an edit is about, for its messages.
fn target_of(edit: &Edit) -> &[String] {
    match edit {
        Edit::Set { path, .. } | Edit::Append { path, .. } => path,
        Edit::Insert { parent, .. } => parent,
    }
}

// --- What an edit means ------------------------------------------------------------------------

fn yaml(text: &str) -> Result<Value, String> {
    serde_yaml_ng::from_str(text).map_err(|e| format!("`{text}` is not YAML: {e}"))
}

fn body_value(body: &Body) -> Result<Value, String> {
    match body {
        Body::Inline(text) => yaml(text),
        Body::Block(lines) if lines.iter().all(|l| l.trim().is_empty()) => Ok(Value::Null),
        Body::Block(lines) => yaml(&lines.join("\n")),
    }
}

/// The mapping at `path` in `value`, made (from nothing or a null) where it is missing.
fn mapping_at<'v>(value: &'v mut Value, path: &[String]) -> Result<&'v mut Mapping, String> {
    let mut here = value;
    for (i, key) in path.iter().enumerate() {
        if here.is_null() {
            *here = Value::Mapping(Mapping::new());
        }
        let Value::Mapping(map) = here else {
            return Err(format!("{} is not a mapping", mapping_name(&path[..i])));
        };
        here = map.entry(Value::String(key.clone())).or_insert(Value::Null);
    }
    if here.is_null() {
        *here = Value::Mapping(Mapping::new());
    }
    match here {
        Value::Mapping(map) => Ok(map),
        _ => Err(format!("{} is not a mapping", mapping_name(path))),
    }
}

/// `value` with `edit` made: what the text must read as afterwards.
fn apply_to_value(value: &mut Value, edit: &Edit) -> Result<(), String> {
    match edit {
        Edit::Set { path, value: new } => {
            let Some((last, parent)) = path.split_last() else {
                return Err("an empty path".to_string());
            };
            let map = mapping_at(value, parent)?;
            let slot = map
                .get_mut(Value::String(last.clone()))
                .ok_or_else(|| format!("`{}` is not there", shown(path)))?;
            *slot = yaml(new)?;
        }
        Edit::Insert {
            parent, key, body, ..
        } => {
            let map = mapping_at(value, parent)?;
            let name = Value::String(key.clone());
            if map.contains_key(&name) {
                return Err(format!("`{key}` is already under `{}`", shown(parent)));
            }
            map.insert(name, body_value(body)?);
        }
        Edit::Append { path, item, .. } => {
            let Some((last, parent)) = path.split_last() else {
                return Err("an empty path".to_string());
            };
            let map = mapping_at(value, parent)?;
            let slot = map
                .entry(Value::String(last.clone()))
                .or_insert(Value::Null);
            if slot.is_null() {
                *slot = Value::Sequence(vec![]);
            }
            let Value::Sequence(items) = slot else {
                return Err(format!("`{}` is not a list", shown(path)));
            };
            items.push(yaml(item)?);
        }
    }
    Ok(())
}

// --- The text ----------------------------------------------------------------------------------

/// One line and the line ending it had (`\n`, `\r\n`, or none for the last line of a file that
/// does not end with one).
#[derive(Debug, Clone)]
struct Line {
    text: String,
    end: String,
}

/// A key found in the text.
#[derive(Debug, Clone)]
struct Node {
    key: String,
    /// The line of `key:`.
    line: usize,
    indent: usize,
    /// The value written after `key:` on its line, as a byte range of it (empty when the value is
    /// the block below, or null).
    value: (usize, usize),
    /// One past the last line of its value (comment and blank lines that end it are not in it).
    end: usize,
}

/// A pubspec as lines, read once.
#[derive(Debug, Clone)]
pub struct Doc {
    lines: Vec<Line>,
    /// Whether the file starts with a byte order mark, which is kept and not part of any line.
    bom: bool,
    /// The line ending of the file, for the lines this adds.
    eol: String,
}

fn indent_of(text: &str) -> usize {
    text.len() - text.trim_start_matches(' ').len()
}

/// Whether a line holds YAML: not blank, not only a comment, and not a document marker.
fn is_content(text: &str) -> bool {
    let t = text.trim();
    !t.is_empty() && !t.starts_with('#') && !is_marker(text)
}

/// A line that is not part of the mapping: `%YAML 1.2` (a directive), `---` (the start of the
/// document) or `...` (its end), each alone on its line at column 0 or followed by a comment. A
/// pubspec can start with them (yamllint asks for `---`), and pub and `serde_yaml_ng` accept it.
/// Text after `---` on its own line is a value, not a marker, so the line is content and the
/// editor refuses the file.
fn is_marker(text: &str) -> bool {
    if text.starts_with('%') {
        return true;
    }
    ["---", "..."].iter().any(|marker| {
        text.strip_prefix(marker).is_some_and(|rest| {
            rest.trim().is_empty()
                || (rest.starts_with([' ', '\t']) && rest.trim_start().starts_with('#'))
        })
    })
}

fn is_comment(text: &str) -> bool {
    text.trim_start().starts_with('#')
}

fn is_item(text: &str) -> bool {
    let t = text.trim_start();
    t == "-" || t.starts_with("- ")
}

/// `key:` at the start of `text` (after its indent): the key, without quotes, and the byte offset
/// that follows the colon. `None` for a sequence item, a comment, or anything else.
fn key_of(text: &str) -> Option<(String, usize)> {
    let indent = indent_of(text);
    let rest = &text[indent..];
    if rest.is_empty() || is_item(rest) || rest.starts_with('#') {
        return None;
    }
    let (key, after) = match rest.as_bytes()[0] {
        quote @ (b'"' | b'\'') => {
            let close = rest[1..].find(quote as char)? + 1;
            (rest[1..close].to_string(), close + 1)
        }
        b'[' | b'{' | b'&' | b'*' | b'!' | b'|' | b'>' | b'?' => return None,
        _ => {
            let colon = rest.char_indices().find_map(|(i, c)| {
                if c != ':' {
                    return None;
                }
                let next = rest[i + 1..].chars().next();
                matches!(next, None | Some(' ' | '\t')).then_some(i)
            })?;
            let key = rest[..colon].trim_end();
            if key.contains(" #") {
                return None;
            }
            (key.to_string(), colon)
        }
    };
    let tail = rest[after..].strip_prefix(':')?;
    if !(tail.is_empty() || tail.starts_with([' ', '\t'])) {
        return None;
    }
    Some((key, indent + after + 1))
}

/// The end of a quoted scalar or a flow collection that starts at `start` (one past its last
/// byte), or the end of the text when it is not closed on this line.
fn scalar_end(text: &str, start: usize) -> usize {
    let bytes = text.as_bytes();
    let mut i = start;
    match bytes[start] {
        b'"' => {
            i += 1;
            while i < bytes.len() {
                match bytes[i] {
                    b'\\' => i += 1,
                    b'"' => return i + 1,
                    _ => {}
                }
                i += 1;
            }
            bytes.len()
        }
        b'\'' => {
            i += 1;
            while i < bytes.len() {
                if bytes[i] == b'\'' {
                    if bytes.get(i + 1) == Some(&b'\'') {
                        i += 2;
                        continue;
                    }
                    return i + 1;
                }
                i += 1;
            }
            bytes.len()
        }
        b'[' | b'{' => {
            let mut depth = 0usize;
            while i < bytes.len() {
                match bytes[i] {
                    b'[' | b'{' => depth += 1,
                    b']' | b'}' => {
                        depth -= 1;
                        if depth == 0 {
                            return i + 1;
                        }
                    }
                    b'"' | b'\'' => {
                        i = scalar_end(text, i);
                        continue;
                    }
                    _ => {}
                }
                i += 1;
            }
            bytes.len()
        }
        _ => {
            // A plain scalar runs to a ` #` comment or the end of the line.
            let mut end = bytes.len();
            for j in start..bytes.len() {
                if bytes[j] == b'#' && j > start && matches!(bytes[j - 1], b' ' | b'\t') {
                    end = j;
                    break;
                }
            }
            start + text[start..end].trim_end().len()
        }
    }
}

/// The value after the colon at `from`: its byte range, empty when there is none.
fn value_span(text: &str, from: usize) -> (usize, usize) {
    let start = from + (text[from..].len() - text[from..].trim_start().len());
    if start >= text.len() || text.as_bytes()[start] == b'#' {
        return (start, start);
    }
    (start, scalar_end(text, start))
}

/// `new` written with the quotes `old` has.
fn requote(old: &str, new: &str) -> String {
    if old.starts_with('"') {
        format!("\"{new}\"")
    } else if old.starts_with('\'') {
        format!("'{new}'")
    } else {
        new.to_string()
    }
}

impl Doc {
    #[must_use]
    pub fn parse(text: &str) -> Doc {
        let eol = if text.contains("\r\n") { "\r\n" } else { "\n" }.to_string();
        let mut lines = vec![];
        let (bom, mut rest) = match text.strip_prefix('\u{feff}') {
            Some(rest) => (true, rest),
            None => (false, text),
        };
        while !rest.is_empty() {
            let (line, end, next) = match rest.find('\n') {
                Some(i) if rest[..i].ends_with('\r') => (&rest[..i - 1], "\r\n", &rest[i + 1..]),
                Some(i) => (&rest[..i], "\n", &rest[i + 1..]),
                None => (rest, "", ""),
            };
            lines.push(Line {
                text: line.to_string(),
                end: end.to_string(),
            });
            rest = next;
        }
        Doc { lines, bom, eol }
    }

    #[must_use]
    pub fn text(&self) -> String {
        let mut out = String::new();
        if self.bom {
            out.push('\u{feff}');
        }
        for line in &self.lines {
            out.push_str(&line.text);
            out.push_str(&line.end);
        }
        out
    }

    fn line(&self, i: usize) -> &str {
        &self.lines[i].text
    }

    /// The indentation the file uses per level: the indent of its first indented `key:` line (2
    /// when it has none). A continuation line of a folded `description: >-` is indented too, and
    /// is no key.
    fn step(&self) -> usize {
        self.lines
            .iter()
            .map(|l| &l.text)
            .filter(|t| is_content(t) && key_of(t).is_some())
            .map(|t| indent_of(t))
            .find(|i| *i > 0)
            .unwrap_or(2)
    }

    /// Where a key at the top level goes last: the end of the file, or before a closing `...`.
    fn top_end(&self) -> usize {
        let last = (0..self.lines.len())
            .rev()
            .find(|i| !self.line(*i).trim().is_empty());
        match last {
            Some(i) if self.line(i).starts_with("...") && is_marker(self.line(i)) => i,
            _ => self.lines.len(),
        }
    }

    /// One past the last line of the value of the key at line `k`, indented `indent`.
    fn block_end(&self, k: usize, indent: usize, inline_empty: bool) -> usize {
        let mut last = k;
        // `key:` with its list items at the key's own indent (`assets:` then `- a`).
        let compact = inline_empty
            && (k + 1..self.lines.len())
                .map(|i| self.line(i))
                .find(|t| is_content(t))
                .is_some_and(|t| indent_of(t) == indent && is_item(t));
        for i in k + 1..self.lines.len() {
            let t = self.line(i);
            if !is_content(t) {
                continue;
            }
            let ind = indent_of(t);
            if ind > indent || (compact && ind == indent && is_item(t)) {
                last = i;
            } else {
                break;
            }
        }
        last + 1
    }

    /// The keys of the mapping in lines `from..to` (the top level is `0..len`). `None` when the
    /// lines are not a block mapping (a list).
    fn children(&self, from: usize, to: usize) -> Option<Vec<Node>> {
        let first = (from..to).find(|i| is_content(self.line(*i)));
        let Some(first) = first else {
            return Some(vec![]);
        };
        let indent = indent_of(self.line(first));
        let mut out = vec![];
        let mut i = first;
        while i < to {
            let t = self.line(i);
            if !is_content(t) || indent_of(t) > indent {
                i += 1;
                continue;
            }
            let (key, after) = key_of(t)?;
            let value = value_span(t, after);
            let end = self.block_end(i, indent, value.0 == value.1);
            out.push(Node {
                key,
                line: i,
                indent,
                value,
                end: end.min(to),
            });
            i = end.max(i + 1);
        }
        Some(out)
    }

    /// The keys of the mapping at `path`, in the order they are written (the top level for `[]`).
    #[cfg(test)]
    pub fn keys(&self, path: &[&str]) -> Option<Vec<String>> {
        let (from, to) = if path.is_empty() {
            (0, self.lines.len())
        } else {
            let node = self.find(&owned(path))?;
            (node.line + 1, node.end)
        };
        Some(
            self.children(from, to)?
                .into_iter()
                .map(|n| n.key)
                .collect(),
        )
    }

    fn find(&self, path: &[String]) -> Option<Node> {
        let (mut from, mut to) = (0, self.lines.len());
        let mut found = None;
        for key in path {
            let node = self
                .children(from, to)?
                .into_iter()
                .find(|n| &n.key == key)?;
            from = node.line + 1;
            to = node.end;
            found = Some(node);
        }
        found
    }

    fn insert_lines(&mut self, at: usize, texts: Vec<String>) {
        // A file that does not end with a newline gets one where a line now follows.
        if at > 0 && self.lines[at - 1].end.is_empty() {
            self.lines[at - 1].end = self.eol.clone();
        }
        let new = texts.into_iter().map(|text| Line {
            text,
            end: self.eol.clone(),
        });
        self.lines.splice(at..at, new);
    }

    fn edit(&mut self, edit: &Edit) -> Result<(), String> {
        match edit {
            Edit::Set { path, value } => self.set(path, value),
            Edit::Insert {
                parent,
                key,
                body,
                comments,
                place,
            } => self.insert(parent, key, body, comments, *place),
            Edit::Append {
                path,
                item,
                comment,
            } => self.append(path, item, comment.as_deref()),
        }
    }

    fn set(&mut self, path: &[String], value: &str) -> Result<(), String> {
        if let Some(node) = self.find(path) {
            let (from, to) = node.value;
            let text = &self.lines[node.line].text;
            let old = &text[from..to];
            if from == to || old.starts_with(['[', '{']) {
                return Err(format!("`{}` has no value on its line", shown(path)));
            }
            let new = format!("{}{}{}", &text[..from], requote(old, value), &text[to..]);
            self.lines[node.line].text = new;
            return Ok(());
        }
        // `git: {url: ..., ref: v1.0.0}`: the last key inside a flow mapping on its parent's line.
        let (last, parent) = path
            .split_last()
            .ok_or_else(|| "an empty path".to_string())?;
        let node = self
            .find(parent)
            .ok_or_else(|| format!("`{}` is not there", shown(path)))?;
        let text = self.lines[node.line].text.clone();
        let (from, to) = node.value;
        if !text[from..to].starts_with('{') {
            return Err(format!("`{}` is not there", shown(path)));
        }
        let (a, b) = flow_value(&text, from + 1, to - 1, last)
            .ok_or_else(|| format!("`{}` is not there", shown(path)))?;
        let new = format!(
            "{}{}{}",
            &text[..a],
            requote(&text[a..b], value),
            &text[b..]
        );
        self.lines[node.line].text = new;
        Ok(())
    }

    fn insert(
        &mut self,
        parent: &[String],
        key: &str,
        body: &Body,
        comments: &[String],
        place: Place,
    ) -> Result<(), String> {
        // A parent that is not there is made inside the nearest one that is.
        let mut there = 0;
        while there < parent.len() && self.find(&parent[..=there]).is_some() {
            there += 1;
        }
        if there < parent.len() {
            let mut lines = vec![];
            let mut pad = String::new();
            for segment in &parent[there + 1..] {
                lines.push(format!("{pad}{segment}:"));
                pad.push_str("  ");
            }
            lines.extend(comments.iter().map(|c| format!("{pad}{c}")));
            match body {
                Body::Inline(value) => lines.push(format!("{pad}{key}: {value}")),
                Body::Block(block) => {
                    lines.push(format!("{pad}{key}:"));
                    lines.extend(block.iter().map(|l| format!("{pad}  {l}")));
                }
            }
            return self.insert(
                &parent[..there],
                &parent[there],
                &Body::Block(lines),
                &[],
                Place::End,
            );
        }
        let top = parent.is_empty();
        let (from, to, parent_indent) = match self.find(parent) {
            Some(node) => {
                if node.value.0 != node.value.1 {
                    return Err(format!(
                        "`{}` is written on one line; fsp adds keys to a block mapping",
                        shown(parent)
                    ));
                }
                (node.line + 1, node.end, Some(node.indent))
            }
            None => (0, self.lines.len(), None),
        };
        let children = self
            .children(from, to)
            .ok_or_else(|| format!("{} is not a block mapping fsp edits", mapping_name(parent)))?;
        if children.iter().any(|c| c.key == key) {
            return Err(format!("`{key}` is already under `{}`", shown(parent)));
        }
        let step = self.step();
        let indent = match (children.first(), parent_indent) {
            (Some(child), _) => child.indent,
            (None, Some(p)) => p + step,
            (None, None) => 0,
        };
        let nested = match parent_indent {
            Some(p) if !children.is_empty() => indent - p,
            _ => step,
        };
        let at = if top {
            self.top_end()
        } else {
            match place {
                Place::End => children.last().map_or(from, |c| c.end),
                Place::Sorted => self
                    .sorted_place(&children, key)
                    .unwrap_or_else(|| children.last().map_or(from, |c| c.end)),
            }
        };
        let pad = " ".repeat(indent);
        let mut texts = vec![];
        if top && at > 0 && !self.line(at - 1).trim().is_empty() {
            texts.push(String::new());
        }
        texts.extend(comments.iter().map(|c| format!("{pad}{c}")));
        match body {
            Body::Inline(value) => texts.push(format!("{pad}{key}: {value}")),
            Body::Block(block) => {
                texts.push(format!("{pad}{key}:"));
                for line in block {
                    let level = indent_of(line) / 2;
                    texts.push(format!(
                        "{}{}",
                        " ".repeat(indent + nested * (level + 1)),
                        line.trim_start()
                    ));
                }
            }
        }
        self.insert_lines(at, texts);
        Ok(())
    }

    /// Where `key` goes in name order among `children`, when they are in name order: before the
    /// first one that sorts after it (and the comment lines right above that one). `None` when it
    /// goes last, or the keys are in no order.
    fn sorted_place(&self, children: &[Node], key: &str) -> Option<usize> {
        let ordered: Vec<&Node> = children
            .iter()
            .filter(|c| {
                !self
                    .children(c.line + 1, c.end)
                    .is_some_and(|under| under.iter().any(|u| u.key == "sdk"))
            })
            .collect();
        if !ordered.windows(2).all(|w| w[0].key <= w[1].key) {
            return None;
        }
        let next = ordered.iter().find(|c| c.key.as_str() > key)?;
        let mut at = next.line;
        while at > 0 && is_comment(self.line(at - 1)) {
            at -= 1;
        }
        Some(at)
    }

    fn append(&mut self, path: &[String], item: &str, comment: Option<&str>) -> Result<(), String> {
        let Some(node) = self.find(path) else {
            let (last, parent) = path
                .split_last()
                .ok_or_else(|| "an empty path".to_string())?;
            return self.insert(
                parent,
                last,
                &Body::Inline(format!("[{item}]")),
                &comment.map(str::to_string).into_iter().collect::<Vec<_>>(),
                Place::End,
            );
        };
        let (from, to) = node.value;
        let text = self.lines[node.line].text.clone();
        let pad = " ".repeat(node.indent);
        if text[from..to].starts_with('[') && text[from..to].ends_with(']') {
            let inner = text[from + 1..to - 1].trim();
            let close = to - 1;
            let added = if inner.is_empty() {
                item.to_string()
            } else {
                // After the last item, before any space that precedes the `]`.
                format!(", {item}")
            };
            let at = if inner.is_empty() {
                close
            } else {
                from + 1 + text[from + 1..close].trim_end().len()
            };
            self.lines[node.line].text = format!("{}{added}{}", &text[..at], &text[at..]);
            if let Some(comment) = comment {
                self.insert_lines(node.line, vec![format!("{pad}{comment}")]);
            }
            return Ok(());
        }
        if from == to {
            let first = (node.line + 1..node.end)
                .map(|i| self.line(i).to_string())
                .find(|t| is_content(t));
            if let Some(first) = first.filter(|t| is_item(t)) {
                let item_pad = " ".repeat(indent_of(&first));
                let mut texts: Vec<String> = comment
                    .map(|c| format!("{item_pad}{c}"))
                    .into_iter()
                    .collect();
                texts.push(format!("{item_pad}- {item}"));
                self.insert_lines(node.end, texts);
                return Ok(());
            }
        }
        Err(format!("`{}` is not a list fsp can add to", shown(path)))
    }
}

/// The value of `key` inside the flow mapping between bytes `from` and `to` of `text` (inside the
/// braces), at its own level: its byte range.
fn flow_value(text: &str, from: usize, to: usize, key: &str) -> Option<(usize, usize)> {
    let bytes = text.as_bytes();
    let mut entry = from;
    let mut i = from;
    while i <= to {
        let at_end = i == to;
        if !at_end {
            match bytes[i] {
                b'"' | b'\'' | b'[' | b'{' => {
                    i = scalar_end(text, i);
                    continue;
                }
                b',' => {}
                _ => {
                    i += 1;
                    continue;
                }
            }
        }
        let piece = &text[entry..i];
        if let Some(colon) = piece.find(':') {
            let name = piece[..colon].trim().trim_matches(['"', '\'']);
            if name == key {
                let value = &piece[colon + 1..];
                let lead = value.len() - value.trim_start().len();
                let start = entry + colon + 1 + lead;
                let end = start + value.trim().len();
                return Some((start, end));
            }
        }
        entry = i + 1;
        i += 1;
    }
    None
}
