//! The platform files `fsp links` edits (since 0.11.0): `AndroidManifest.xml` and the
//! `.entitlements` plists, each opt-in through a key of `links:`.
//!
//! No XML crate: a small scanner skips comments, CDATA and the prolog, and reads tags with
//! their attributes. What it finds decides where text goes, and the text outside that place is
//! never rewritten, so a second run changes nothing and Xcode's or Android Studio's own edits
//! stay.
//!
//! - **The manifest** gets the intent filters between two comment markers inside the one
//!   `<activity>` with the `MAIN` intent filter (an `<activity-alias>` and a comment don't
//!   count). The first run finds that activity and inserts the markers before its
//!   `</activity>`; later runs replace what is between them. The markers can also be written by
//!   hand, for a manifest this scanner can't place them in.
//! - **An entitlements file** gets its `applinks:` entries in the
//!   `com.apple.developer.associated-domains` array. Other entries of the array
//!   (`webcredentials:`, `activitycontinuation:`) stay, with the `applinks:` ones after them. A
//!   file that doesn't exist is written whole.
//!
//! The text of a plan is a function of the file and the config, so `fsp links --check` can
//! compare it with the disk. Line endings are the file's own.

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

use anyhow::{Result, bail};

use crate::config::Links;
use crate::links::{entitlements, xml_attr};

/// The `begin` marker `fsp links` writes. A hand-written `<!-- fsp links: begin -->` works too.
const BEGIN: &str = "<!-- fsp links: begin. Written from lib/app by `fsp links`; change links: in pubspec.yaml, not these lines. -->";
const END: &str = "<!-- fsp links: end -->";
const MAIN_ACTION: &str = "android.intent.action.MAIN";
const VIEW_ACTION: &str = "android.intent.action.VIEW";
/// The entitlement key `fsp links` edits.
const DOMAINS_KEY: &str = "com.apple.developer.associated-domains";

// --- A small XML scanner -------------------------------------------------------

/// A byte range of the text.
type Range = (usize, usize);

/// One start, end or empty-element tag.
#[derive(Debug)]
struct Tag {
    name: String,
    close: bool,
    self_closing: bool,
    start: usize,
    end: usize,
    attrs: Vec<(String, String)>,
}

/// The tags of a document and the byte ranges of its comments.
#[derive(Debug)]
struct Scan {
    tags: Vec<Tag>,
    comments: Vec<(usize, usize)>,
}

fn is_space(b: u8) -> bool {
    b.is_ascii_whitespace()
}

/// The end of a `<!DOCTYPE ...>` that starts at `i`, quotes and `[...]` taken into account.
fn doctype_end(b: &[u8], i: usize) -> Option<usize> {
    let (mut depth, mut quote) = (0usize, None);
    for (j, &c) in b.iter().enumerate().skip(i + 2) {
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (Some(_), _) => {}
            (None, b'"' | b'\'') => quote = Some(c),
            (None, b'[') => depth += 1,
            (None, b']') => depth = depth.saturating_sub(1),
            (None, b'>') if depth == 0 => return Some(j + 1),
            _ => {}
        }
    }
    None
}

/// Reads one tag that starts at `i` (a `<`).
fn read_tag(text: &str, i: usize) -> Option<Tag> {
    let b = text.as_bytes();
    let mut j = i + 1;
    let close = b.get(j) == Some(&b'/');
    if close {
        j += 1;
    }
    let name_start = j;
    while j < b.len() && !is_space(b[j]) && !matches!(b[j], b'/' | b'>') {
        j += 1;
    }
    if j == name_start {
        return None;
    }
    let name = text[name_start..j].to_string();
    let mut attrs = vec![];
    loop {
        while j < b.len() && is_space(b[j]) {
            j += 1;
        }
        match *b.get(j)? {
            b'>' => {
                return Some(Tag {
                    name,
                    close,
                    self_closing: false,
                    start: i,
                    end: j + 1,
                    attrs,
                });
            }
            b'/' => {
                return (b.get(j + 1) == Some(&b'>')).then_some(Tag {
                    name,
                    close,
                    self_closing: true,
                    start: i,
                    end: j + 2,
                    attrs,
                });
            }
            _ => {
                let key_start = j;
                while j < b.len() && !is_space(b[j]) && !matches!(b[j], b'=' | b'>' | b'/') {
                    j += 1;
                }
                let key = text[key_start..j].to_string();
                while j < b.len() && is_space(b[j]) {
                    j += 1;
                }
                let mut value = String::new();
                if b.get(j) == Some(&b'=') {
                    j += 1;
                    while j < b.len() && is_space(b[j]) {
                        j += 1;
                    }
                    let quote = *b.get(j)?;
                    if !matches!(quote, b'"' | b'\'') {
                        return None;
                    }
                    let len = text[j + 1..].find(char::from(quote))?;
                    value = text[j + 1..j + 1 + len].to_string();
                    j += len + 2;
                }
                if key.is_empty() {
                    return None;
                }
                attrs.push((key, value));
            }
        }
    }
}

/// The tags and comments of `text`; `None` when it is not well-formed enough to read.
fn scan(text: &str) -> Option<Scan> {
    let b = text.as_bytes();
    let (mut tags, mut comments) = (vec![], vec![]);
    let mut i = 0;
    while i < b.len() {
        if b[i] != b'<' {
            i += 1;
            continue;
        }
        let rest = &text[i..];
        if let Some(after) = rest.strip_prefix("<!--") {
            let end = i + 4 + after.find("-->")? + 3;
            comments.push((i, end));
            i = end;
        } else if rest.starts_with("<![CDATA[") {
            i += rest.find("]]>")? + 3;
        } else if rest.starts_with("<?") {
            i += rest.find("?>")? + 2;
        } else if rest.starts_with("<!") {
            i = doctype_end(b, i)?;
        } else {
            let tag = read_tag(text, i)?;
            i = tag.end;
            tags.push(tag);
        }
    }
    Some(Scan { tags, comments })
}

/// An element, with where its parts are in the text.
#[derive(Debug)]
struct Node {
    name: String,
    attrs: Vec<(String, String)>,
    start: usize,
    /// The end of the start tag.
    open_end: usize,
    /// The start of the end tag (the end of the element for an empty one).
    close_start: usize,
    end: usize,
    self_closing: bool,
    children: Vec<usize>,
    parent: Option<usize>,
}

impl Node {
    fn attr(&self, name: &str) -> Option<&str> {
        self.attrs
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }
}

/// The elements of a scan, parents before children, and the top-level ones. `None` when the
/// tags don't nest.
fn tree(scan: &Scan) -> Option<(Vec<Node>, Vec<usize>)> {
    let (mut nodes, mut roots): (Vec<Node>, Vec<usize>) = (vec![], vec![]);
    let mut stack: Vec<usize> = vec![];
    for t in &scan.tags {
        if t.close {
            let open = stack.pop()?;
            if nodes[open].name != t.name {
                return None;
            }
            nodes[open].close_start = t.start;
            nodes[open].end = t.end;
            continue;
        }
        let parent = stack.last().copied();
        let id = nodes.len();
        nodes.push(Node {
            name: t.name.clone(),
            attrs: t.attrs.clone(),
            start: t.start,
            open_end: t.end,
            close_start: t.end,
            end: t.end,
            self_closing: t.self_closing,
            children: vec![],
            parent,
        });
        match parent {
            Some(p) => nodes[p].children.push(id),
            None => roots.push(id),
        }
        if !t.self_closing {
            stack.push(id);
        }
    }
    stack.is_empty().then_some((nodes, roots))
}

// --- Lines ---------------------------------------------------------------------

/// The line ending the file uses: its first one.
fn eol_of(text: &str) -> &'static str {
    match text.find('\n') {
        Some(i) if text[..i].ends_with('\r') => "\r\n",
        _ => "\n",
    }
}

/// The start of the line `pos` is on.
fn line_start(text: &str, pos: usize) -> usize {
    text[..pos].rfind('\n').map_or(0, |i| i + 1)
}

/// The end of the line `pos` is on, before its line ending.
fn line_end(text: &str, pos: usize) -> usize {
    let end = text[pos..].find('\n').map_or(text.len(), |i| pos + i);
    if text[..end].ends_with('\r') {
        end - 1
    } else {
        end
    }
}

/// The white space a line starts with.
fn indent_at(text: &str, pos: usize) -> &str {
    let start = line_start(text, pos);
    let rest = &text[start..];
    &rest[..rest.len() - rest.trim_start_matches([' ', '\t']).len()]
}

/// Whether only white space comes before `pos` on its line.
fn starts_line(text: &str, pos: usize) -> bool {
    text[line_start(text, pos)..pos]
        .chars()
        .all(|c| c == ' ' || c == '\t')
}

/// The 1-based line number of `pos`.
fn line_number(text: &str, pos: usize) -> usize {
    text[..pos].matches('\n').count() + 1
}

// --- AndroidManifest.xml ---------------------------------------------------------

/// What the manifest held before an edit.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Was {
    /// The markers are there and what is between them is what `fsp links` writes.
    Current,
    /// The markers are there, and what is between them is something else.
    OutOfDate,
    /// There are no markers yet.
    NoMarkers,
}

fn no_activity(path: &str) -> anyhow::Error {
    anyhow::anyhow!(
        "{path}: no single <activity> with the MAIN/LAUNCHER intent filter to put the link filters in; add `<!-- fsp links: begin -->` and `<!-- fsp links: end -->` on two lines inside the activity that opens links, and run `fsp links` again"
    )
}

fn bad_markers(path: &str) -> anyhow::Error {
    anyhow::anyhow!(
        "{path}: `<!-- fsp links: begin -->` and `<!-- fsp links: end -->` must each appear once, the begin first"
    )
}

/// The comment markers of `text`: `(begin, end)` byte ranges, or `None` for none at all.
fn markers(path: &str, text: &str, scan: &Scan) -> Result<Option<(Range, Range)>> {
    let inner = |c: &(usize, usize)| text[c.0 + 4..c.1 - 3].trim();
    let begins: Vec<_> = scan
        .comments
        .iter()
        .filter(|c| {
            inner(c)
                .strip_prefix("fsp links: begin")
                .is_some_and(|rest| {
                    rest.is_empty() || rest.starts_with(|ch: char| ch == '.' || ch.is_whitespace())
                })
        })
        .collect();
    let ends: Vec<_> = scan
        .comments
        .iter()
        .filter(|c| inner(c) == "fsp links: end")
        .collect();
    match (begins.as_slice(), ends.as_slice()) {
        ([], []) => Ok(None),
        ([b], [e]) if b.1 <= e.0 => {
            let alone = |c: &(usize, usize)| {
                starts_line(text, c.0) && text[c.1..line_end(text, c.1)].trim().is_empty()
            };
            if alone(b) && alone(e) {
                Ok(Some((**b, **e)))
            } else {
                Err(bad_markers(path))
            }
        }
        _ => Err(bad_markers(path)),
    }
}

/// The `</activity>` of the one activity with the `MAIN` action in an intent filter.
fn main_activity_end(text: &str) -> Option<usize> {
    let (nodes, _) = tree(&scan(text)?)?;
    let mut found: BTreeSet<usize> = BTreeSet::new();
    for n in &nodes {
        if n.name != "action" || n.attr("android:name") != Some(MAIN_ACTION) {
            continue;
        }
        let Some(filter) = n.parent.filter(|p| nodes[*p].name == "intent-filter") else {
            continue;
        };
        if let Some(activity) = nodes[filter]
            .parent
            .filter(|p| nodes[*p].name == "activity")
        {
            found.insert(activity);
        }
    }
    let [activity] = found.into_iter().collect::<Vec<_>>()[..] else {
        return None;
    };
    (!nodes[activity].self_closing).then_some(nodes[activity].close_start)
}

/// The lines of `filters` at `indent`, each ended by `eol`.
fn indented(filters: &str, indent: &str, eol: &str) -> String {
    let mut out = String::new();
    for line in filters.lines() {
        if !line.is_empty() {
            out.push_str(indent);
            let body = line.trim_start_matches(' ');
            let steps = (line.len() - body.len()) / 4;
            // A tab-indented file gets tabs for the filter's own nesting too.
            out.push_str(&if indent.contains('\t') {
                "\t".repeat(steps)
            } else {
                " ".repeat(steps * 4)
            });
            out.push_str(body);
        }
        out.push_str(eol);
    }
    out
}

/// `current` (the manifest at `path`) with `filters` between the markers: the text to write and
/// what the file was. Nothing outside the markers changes.
///
/// # Errors
/// When there are markers that aren't a pair of lines, or no markers and no single
/// `<activity>` to put them in.
pub fn edit_manifest(path: &str, current: &str, filters: &str) -> Result<(String, Was)> {
    let eol = eol_of(current);
    let scan = scan(current).ok_or_else(|| no_activity(path))?;
    if let Some(((begin, _), (end, _))) = markers(path, current, &scan)? {
        let (nodes, _) = tree(&scan).ok_or_else(|| no_activity(path))?;
        let enclosing = |pos: usize| {
            nodes
                .iter()
                .enumerate()
                .filter(|(_, n)| n.start < pos && pos < n.close_start)
                .max_by_key(|(_, n)| n.start)
                .map(|(i, _)| i)
        };
        let (at_begin, at_end) = (enclosing(begin), enclosing(end));
        let in_activity = at_begin == at_end
            && at_begin
                .is_some_and(|i| matches!(nodes[i].name.as_str(), "activity" | "activity-alias"));
        if !in_activity {
            return Err(anyhow::anyhow!(
                "{path}: the fsp links markers are not inside an <activity>, where Android reads intent filters; move both onto lines of their own inside the activity that opens links"
            ));
        }
        let le = line_end(current, begin);
        let from = le
            + if current[le..].starts_with("\r\n") {
                2
            } else {
                usize::from(current[le..].starts_with('\n'))
            };
        let to = line_start(current, end);
        let body = indented(filters, indent_at(current, begin), eol);
        if from > to {
            return Err(bad_markers(path));
        }
        if current[from..to] == body {
            return Ok((current.to_string(), Was::Current));
        }
        let mut text = String::from(&current[..from]);
        text.push_str(&body);
        text.push_str(&current[to..]);
        return Ok((text, Was::OutOfDate));
    }
    let close = main_activity_end(current).ok_or_else(|| no_activity(path))?;
    if !starts_line(current, close) {
        return Err(no_activity(path));
    }
    let at = line_start(current, close);
    let outer = indent_at(current, close);
    let indent = format!(
        "{outer}{}",
        if outer.contains('\t') { "\t" } else { "    " }
    );
    let mut block = format!("{indent}{BEGIN}{eol}");
    block.push_str(&indented(filters, &indent, eol));
    block.push_str(&format!("{indent}{END}{eol}"));
    let mut text = String::from(&current[..at]);
    text.push_str(&block);
    text.push_str(&current[at..]);
    Ok((text, Was::NoMarkers))
}

/// The warnings of `<intent-filter>`s outside the markers that open what `fsp links` writes a
/// filter for: a VIEW filter for one of the domains, or for the scheme without a host.
#[must_use]
pub fn foreign_filters(path: &str, text: &str, cfg: &Links) -> Vec<String> {
    let Some(scan) = scan(text) else {
        return vec![];
    };
    let Some((nodes, _)) = tree(&scan) else {
        return vec![];
    };
    let inside = markers(path, text, &scan)
        .ok()
        .flatten()
        .map(|((b, _), (_, e))| (b, e));
    let mut out = vec![];
    for filter in nodes.iter().filter(|n| n.name == "intent-filter") {
        if inside.is_some_and(|(b, e)| filter.start > b && filter.start < e) {
            continue;
        }
        if matches!(filter.attr("tools:node"), Some("remove" | "removeAll")) {
            continue;
        }
        let kids: Vec<&Node> = filter.children.iter().map(|c| &nodes[*c]).collect();
        let view = kids
            .iter()
            .any(|k| k.name == "action" && k.attr("android:name") == Some(VIEW_ACTION));
        let data = |attr: &str| -> Vec<String> {
            kids.iter()
                .filter(|k| k.name == "data")
                .filter_map(|k| k.attr(attr).map(str::to_ascii_lowercase))
                .collect()
        };
        let (schemes, hosts) = (data("android:scheme"), data("android:host"));
        if !view {
            continue;
        }
        let scheme_listed = |s: &str| schemes.iter().any(|x| x == s);
        let ours = cfg.scheme.as_deref().is_some_and(scheme_listed);
        let web = scheme_listed("https") || scheme_listed("http");
        let host = hosts
            .iter()
            .find(|h| cfg.domains.contains(h) && (web || ours))
            .cloned()
            .or_else(|| {
                let scheme = cfg.scheme.as_deref()?;
                (ours && hosts.is_empty()).then(|| format!("{scheme}://"))
            });
        if let Some(host) = host {
            out.push(format!(
                "{path}:{}: an <intent-filter> for `{host}` outside the fsp links markers; remove it, `fsp links` writes that filter now",
                line_number(text, filter.start)
            ));
        }
    }
    out
}

// --- Flutter's deep linking switch ------------------------------------------------------

/// What follows the name of the warning in both files.
const DEEPLINKING_OFF: &str = "Flutter will not hand links to the router (intended with a deep-link plugin: see docs/navigation.md, \"With a deep-link plugin\")";

/// Where `flutter create` writes the manifest.
const DEFAULT_MANIFEST: &str = "android/app/src/main/AndroidManifest.xml";

/// The `Info.plist` of the Runner target, read for [`ios_deeplinking_off`].
pub const INFO_PLIST: &str = "ios/Runner/Info.plist";

/// The warning when the manifest turns Flutter's deep linking off, with
/// `<meta-data android:name="flutter_deeplinking_enabled" android:value="false" />`. Read only:
/// `fsp links` never edits that tag.
#[must_use]
pub fn android_deeplinking_off(path: &str, text: &str) -> Option<String> {
    let scan = scan(text)?;
    let off = scan.tags.iter().any(|t| {
        t.name == "meta-data"
            && !t.close
            && t.attrs
                .iter()
                .any(|(k, v)| k == "android:name" && v == "flutter_deeplinking_enabled")
            && t.attrs
                .iter()
                .any(|(k, v)| k == "android:value" && v.trim().eq_ignore_ascii_case("false"))
    });
    off.then(|| format!("flutter_deeplinking_enabled is false in {path}: {DEEPLINKING_OFF}"))
}

/// The warning when `Info.plist` has `FlutterDeepLinkingEnabled` set to `<false/>`. Read only.
#[must_use]
pub fn ios_deeplinking_off(path: &str, text: &str) -> Option<String> {
    let mut plain = String::new();
    let mut rest = text;
    while let Some(i) = rest.find("<!--") {
        plain.push_str(&rest[..i]);
        // An unterminated comment runs to the end of the file.
        let close = rest[i..].find("-->").map_or(rest.len(), |j| i + j + 3);
        rest = &rest[close..];
    }
    plain.push_str(rest);
    let key = "<key>FlutterDeepLinkingEnabled</key>";
    let after = plain[plain.find(key)? + key.len()..].trim_start();
    let off = after
        .strip_prefix("<false")
        .is_some_and(|r| r.trim_start().starts_with('/') || r.starts_with('>'));
    off.then(|| format!("FlutterDeepLinkingEnabled is false in {path}: {DEEPLINKING_OFF}"))
}

// --- .entitlements -----------------------------------------------------------------

fn not_a_plist(path: &str) -> anyhow::Error {
    anyhow::anyhow!(
        "{path}: not an XML property list with a <dict> at the top; fsp links edits only `{DOMAINS_KEY}` in it"
    )
}

fn not_an_array(path: &str) -> anyhow::Error {
    anyhow::anyhow!(
        "{path}: `{DOMAINS_KEY}` is not an <array>; fix it by hand, fsp links only edits an array"
    )
}

/// The indentation step that goes with `indent`: a tab for tabs (and for none), else two spaces.
fn unit_of(indent: &str) -> &'static str {
    if indent.is_empty() || indent.contains('\t') {
        "\t"
    } else {
        "  "
    }
}

fn applinks(domains: &[String]) -> Vec<String> {
    domains
        .iter()
        .map(|d| format!("<string>applinks:{}</string>", xml_attr(d)))
        .collect()
}

/// The entry `<key>` and `<array>` of the domains, at `indent`.
fn domains_entry(domains: &[String], indent: &str, eol: &str) -> String {
    let unit = unit_of(indent);
    let mut out = format!("{indent}<key>{DOMAINS_KEY}</key>{eol}{indent}<array>{eol}");
    for s in applinks(domains) {
        out.push_str(&format!("{indent}{unit}{s}{eol}"));
    }
    out.push_str(&format!("{indent}</array>{eol}"));
    out
}

/// The text of a new entitlements file for `domains`.
#[must_use]
pub fn new_entitlements(domains: &[String]) -> String {
    entitlements(domains, None)
}

/// `current` (the plist at `path`) with the `applinks:` entries of `domains` in its
/// associated-domains array. Only `fsp`'s own `applinks:` items are removed and rewritten (the
/// rest of the file stays byte for byte), and the new ones go before the array's end. Also the
/// warnings for each removed entry whose host isn't one of the domains.
///
/// # Errors
/// When the file isn't a property list with a `<dict>` at the top, or its
/// `com.apple.developer.associated-domains` is not an `<array>`.
pub fn edit_entitlements(
    path: &str,
    current: &str,
    domains: &[String],
) -> Result<(String, Vec<String>)> {
    let eol = eol_of(current);
    let (nodes, roots) = scan(current)
        .and_then(|s| tree(&s))
        .ok_or_else(|| not_a_plist(path))?;
    let [root] = roots[..] else {
        return Err(not_a_plist(path));
    };
    let dict = (nodes[root].name == "plist")
        .then(|| nodes[root].children.first().copied())
        .flatten()
        .filter(|d| nodes[*d].name == "dict")
        .ok_or_else(|| not_a_plist(path))?;
    let dict = &nodes[dict];
    let kids: Vec<&Node> = dict.children.iter().map(|c| &nodes[*c]).collect();
    let key_text = |k: &Node| current[k.open_end..k.close_start].trim();
    let pos = kids
        .iter()
        .position(|k| k.name == "key" && key_text(k) == DOMAINS_KEY);

    let Some(pos) = pos else {
        // No entry yet: add one at the end of the dict.
        if dict.self_closing {
            let indent = indent_at(current, dict.start);
            let unit = unit_of(indent);
            let entry = domains_entry(domains, &format!("{indent}{unit}"), eol);
            let mut text = String::from(&current[..dict.start]);
            text.push_str(&format!("<dict>{eol}{entry}{indent}</dict>"));
            text.push_str(&current[dict.end..]);
            return Ok((text, vec![]));
        }
        let indent = match kids.last() {
            Some(last) if starts_line(current, last.start) => {
                indent_at(current, last.start).to_string()
            }
            _ => {
                let outer = indent_at(current, dict.start);
                format!("{outer}{}", unit_of(outer))
            }
        };
        let entry = domains_entry(domains, &indent, eol);
        let mut text = String::from(&current[..dict.close_start]);
        if starts_line(current, dict.close_start) {
            let at = line_start(current, dict.close_start);
            text.truncate(at);
            text.push_str(&entry);
            text.push_str(&current[at..]);
        } else {
            text.push_str(eol);
            text.push_str(&entry);
            text.push_str(&current[dict.close_start..]);
        }
        return Ok((text, vec![]));
    };

    let array = kids
        .get(pos + 1)
        .filter(|a| a.name == "array")
        .ok_or_else(|| not_an_array(path))?;
    let outer = if starts_line(current, array.start) {
        indent_at(current, array.start)
    } else {
        indent_at(current, kids[pos].start)
    };
    let items: Vec<&Node> = array.children.iter().map(|c| &nodes[*c]).collect();
    let item_indent = match items.first() {
        Some(first) if starts_line(current, first.start) => {
            indent_at(current, first.start).to_string()
        }
        _ => format!("{outer}{}", unit_of(outer)),
    };
    let owned = |n: &Node| {
        n.name == "string"
            && current[n.open_end..n.close_start]
                .trim()
                .starts_with("applinks:")
    };
    let mine: Vec<&Node> = items.iter().copied().filter(|n| owned(n)).collect();
    let wanted = applinks(domains);
    if mine.len() == wanted.len()
        && mine
            .iter()
            .zip(&wanted)
            .all(|(n, w)| current[n.start..n.end] == *w)
    {
        return Ok((current.to_string(), vec![]));
    }
    // fsp owns every applinks: entry; one whose host isn't a domain is dropped, with a warning.
    let mut removed = vec![];
    for n in &mine {
        let entry = current[n.open_end..n.close_start].trim();
        let host = entry["applinks:".len()..]
            .split('?')
            .next()
            .unwrap_or_default()
            .to_ascii_lowercase();
        if !domains.contains(&host) {
            removed.push(format!(
                "{path}: removed `{entry}` from `{DOMAINS_KEY}`: fsp links owns every applinks: entry, and `{host}` is not in `fespalier.links.domains`"
            ));
        }
    }
    let lines: String = wanted
        .iter()
        .map(|s| format!("{item_indent}{s}{eol}"))
        .collect();
    let mut text = current.to_string();
    // Only the applinks: items go (their whole line when they have it to themselves).
    for n in mine.iter().rev() {
        let (from, to) = if starts_line(&text, n.start)
            && text[n.end..line_end(&text, n.end)].trim().is_empty()
        {
            let le = line_end(&text, n.end);
            let nl = if text[le..].starts_with("\r\n") {
                2
            } else {
                usize::from(text[le..].starts_with('\n'))
            };
            (line_start(&text, n.start), le + nl)
        } else {
            (n.start, n.end)
        };
        text.replace_range(from..to, "");
    }
    // The array's own end moved by what was removed before it.
    let shift = current.len() - text.len();
    if array.self_closing {
        text.replace_range(
            array.start..array.end,
            &format!("<array>{eol}{lines}{outer}</array>"),
        );
    } else {
        let close = array.close_start - shift;
        if starts_line(&text, close) {
            text.insert_str(line_start(&text, close), &lines);
        } else {
            text.insert_str(close, &format!("{eol}{lines}{outer}"));
        }
    }
    Ok((text, removed))
}

/// Whether `ios/Runner.xcodeproj/project.pbxproj` sets `CODE_SIGN_ENTITLEMENTS` to `rel`, a
/// path relative to ios/.
pub(crate) fn pbxproj_references(pbxproj: &str, rel: &str) -> bool {
    pbxproj
        .lines()
        .filter_map(|l| l.trim().strip_prefix("CODE_SIGN_ENTITLEMENTS"))
        .filter_map(|l| l.trim_start().strip_prefix('='))
        .any(|v| {
            let v = v.trim().trim_end_matches(';').trim().trim_matches('"');
            let v = [
                "$(SRCROOT)/",
                "${SRCROOT}/",
                "$(PROJECT_DIR)/",
                "${PROJECT_DIR}/",
                "$(SOURCE_ROOT)/",
                "${SOURCE_ROOT}/",
                "./",
            ]
            .iter()
            .find_map(|p| v.strip_prefix(p))
            .unwrap_or(v);
            v == rel
        })
}

/// The warning for an entitlements file no build setting names, when the Xcode project is there.
fn unreferenced(project: &Path, path: &str) -> Option<String> {
    let pbxproj = fs::read_to_string(project.join("ios/Runner.xcodeproj/project.pbxproj")).ok()?;
    let rel = path.strip_prefix("ios/").unwrap_or(path);
    (!pbxproj_references(&pbxproj, rel)).then(|| {
        format!(
            "{path} is not set as CODE_SIGN_ENTITLEMENTS in ios/Runner.xcodeproj/project.pbxproj, so no build uses it: add the Associated Domains capability in Xcode, or point the build setting at this file"
        )
    })
}

// --- The plan ------------------------------------------------------------------------

/// One platform file after `fsp links`: what it should hold, and why it is not that now.
#[derive(Debug, PartialEq, Eq)]
pub struct Planned {
    /// Relative to the project root, `/`-separated.
    pub path: String,
    /// The file as it should be.
    pub text: String,
    /// The `--check` line when the disk differs, `None` when it already is `text`.
    pub stale: Option<String>,
    /// Whether the file doesn't exist yet.
    pub created: bool,
}

/// A file's text; the edit writes the whole file back, so one that isn't UTF-8 is refused
/// instead of being changed outside the markers.
fn utf8(path: &str, bytes: Vec<u8>) -> Result<String> {
    String::from_utf8(bytes)
        .map_err(|_| anyhow::anyhow!("{path} is not UTF-8; fsp links edits only UTF-8 files"))
}

/// The platform files `cfg` names, as they should be, and the warnings met on the way.
///
/// `filters` are the intent filters, without a comment, one element per line.
///
/// # Errors
/// When a file can't be edited: the manifest is missing, has no place for the filters or
/// broken markers, or an entitlements file isn't a property list `fsp links` can edit.
pub fn plan(project: &Path, cfg: &Links, filters: &str) -> Result<(Vec<Planned>, Vec<String>)> {
    let (mut files, mut warnings) = (vec![], vec![]);
    let read = |path: &str| fs::read(project.join(path)).ok();
    if let Some(path) = &cfg.android_manifest {
        let Some(bytes) = read(path) else {
            bail!(
                "{path} not found (`fespalier.links.android_manifest`); run `flutter create --platforms android .`, or fix the path"
            );
        };
        let current = utf8(path, bytes)?;
        warnings.extend(foreign_filters(path, &current, cfg));
        warnings.extend(android_deeplinking_off(path, &current));
        let (text, was) = edit_manifest(path, &current, filters)?;
        let stale = match was {
            Was::Current => None,
            Was::OutOfDate => Some(format!(
                "{path}: the intent filters between the fsp links markers are out of date"
            )),
            Was::NoMarkers => Some(format!("{path} has no fsp links markers yet")),
        };
        files.push(Planned {
            path: path.clone(),
            text,
            stale,
            created: false,
        });
    }
    let mut seen: BTreeSet<&str> = BTreeSet::new();
    for path in cfg
        .apps_ios
        .iter()
        .filter_map(|a| a.entitlements.as_deref())
    {
        if !seen.insert(path) {
            continue;
        }
        warnings.extend(unreferenced(project, path));
        files.push(match read(path) {
            None => {
                let folder = path.rsplit_once('/').map_or("ios", |(f, _)| f);
                if !project.join(folder).is_dir() {
                    bail!(
                        "{path}: the folder {folder} does not exist; fsp links writes the file, not the iOS project: run `flutter create --platforms ios .`, or create the folder"
                    );
                }
                Planned {
                path: path.to_string(),
                text: new_entitlements(&cfg.domains),
                stale: Some(format!("{path} is missing")),
                created: true,
                }
            }
            Some(bytes) => {
                let current = utf8(path, bytes)?;
                let (text, removed) = edit_entitlements(path, &current, &cfg.domains)?;
                warnings.extend(removed);
                let stale = (text != current).then(|| {
                    format!("{path}: the applinks: entries of {DOMAINS_KEY} are out of date")
                });
                Planned {
                    path: path.to_string(),
                    text,
                    stale,
                    created: false,
                }
            }
        });
    }
    // Flutter's own switch, read where `flutter create` puts it, whether or not `fsp links` edits
    // the file: the manifest only when `android_manifest:` did not name it already.
    let text_of = |path: &str| read(path).and_then(|b| String::from_utf8(b).ok());
    if cfg.android_manifest.is_none()
        && !cfg.apps_android.is_empty()
        && let Some(text) = text_of(DEFAULT_MANIFEST)
    {
        warnings.extend(android_deeplinking_off(DEFAULT_MANIFEST, &text));
    }
    if !cfg.apps_ios.is_empty()
        && let Some(text) = text_of(INFO_PLIST)
    {
        warnings.extend(ios_deeplinking_off(INFO_PLIST, &text));
    }
    Ok((files, warnings))
}
