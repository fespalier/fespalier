//! Lints over the app's own code: string paths given to the router that match no route.
//!
//! `context.go('/prodcts/2')` compiles, runs, and shows `not_found.dart`. The typed routes
//! (`ProductRoute(id: 2).go(context)`) cannot be misspelled, but a string path is allowed
//! (a CMS link, a notification payload, a path from another router), so `fsp` does not forbid it;
//! it checks that the path **matches a route**, the way `AppRoutes.matchUrl` would.
//!
//! This reads a syntax tree, not the analyzer: it cannot know that `context` is a
//! `BuildContext`. It only ever looks at string literals in a few call shapes ([`SiteKind`]),
//! which is where a syntax tree is as good as the analyzer, and it flags a path only when it
//! is sure: a path it cannot read (a relative one, a URL, `'$base/x'`, one with a `..`) is
//! skipped, never guessed at.
//!
//! [`sites`] reads one file and is pure; [`check`] walks `lib/`, finds the mount point, and
//! matches every site against a [`Table`] built from the resolved tree.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::Path;
use std::rc::Rc;

use tree_sitter::{Node, Parser};

use crate::config::{Config, LintLevel};
use crate::dart::Span;
use crate::diag::{Base, Diags, Level};
use crate::locale::{self, Localized};
use crate::resolve::App;
use crate::scan::Seg;

/// The id a lint goes by, in `lints:` and in `// fsp:ignore`.
const ID: &str = "unknown_path";

/// A file that contains none of these cannot hold a site, so it is not parsed.
const MARKERS: [&str; 8] = [
    "go(",
    "push(",
    "push<",
    "replace(",
    "pushReplacement(",
    "RouteLink",
    "initialLocation",
    "mount(",
];

/// The methods whose first argument is a location.
const NAVIGATE: [&str; 4] = ["go", "push", "pushReplacement", "replace"];

// --- Sites ------------------------------------------------------------------------------

/// One piece of a string literal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Piece {
    /// Characters, with escapes applied.
    Text(String),
    /// An interpolation (`$id`, `${a.b}`): any text.
    Hole,
}

/// What a site hands the string to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SiteKind {
    /// `context.go('/x')`, `router.push<int>('/x')`, `.replace(...)`, `.pushReplacement(...)`.
    Navigate,
    /// `RouteLink(uri: Uri.parse('/x'))`.
    RouteLinkUri,
    /// `AppRoutes.router(initialLocation: '/x')`, `GoRouter(initialLocation: '/x')`.
    InitialLocation,
    /// `AppRoutes.mount(at: '/shop')`: not checked, it sets where the tree is mounted.
    Mount(MountAt),
}

/// The `at:` of an `AppRoutes.mount(...)` call.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MountAt {
    /// No `at:`: the tree is mounted at `/`.
    Default,
    /// A string literal.
    Literal(Vec<Piece>),
    /// Anything else (a variable, an expression): the mount point is not known.
    Unknown,
}

/// A place in a Dart file that gives the router a string.
#[derive(Debug, Clone, PartialEq)]
pub struct Site {
    pub kind: SiteKind,
    /// The literal, read. Empty for a [`SiteKind::Mount`].
    pub pieces: Vec<Piece>,
    /// The literal as written, without its quotes.
    pub text: String,
    /// The literal, quotes included.
    pub span: Span,
    /// The line (1-based) the call starts on.
    pub call_line: usize,
    /// The line (1-based) the literal ends on.
    pub end_line: usize,
    /// Silenced by `// fsp:ignore unknown_path` or `// fsp:ignore-file unknown_path`.
    pub ignored: bool,
}

/// The sites of one file.
pub fn sites(src: &str) -> Vec<Site> {
    let mut parser = Parser::new();
    if parser
        .set_language(&tree_sitter_dart::LANGUAGE.into())
        .is_err()
    {
        return vec![];
    }
    let Some(tree) = parser.parse(src, None) else {
        return vec![];
    };
    let mut out = vec![];
    let mut cursor = tree.root_node().walk();
    'walk: loop {
        visit(cursor.node(), src, &mut out);
        if cursor.goto_first_child() {
            continue;
        }
        while !cursor.goto_next_sibling() {
            if !cursor.goto_parent() {
                break 'walk;
            }
        }
    }
    let ignores = Ignores::read(src);
    for s in &mut out {
        s.ignored = ignores.silences(s);
    }
    out
}

/// What a call node is, as far as the lint cares.
enum Callee<'a> {
    /// `receiver.method(...)`, `receiver?.method(...)`, `receiver.method<T>(...)`.
    Method { receiver: Node<'a>, name: &'a str },
    /// `Name(...)`.
    Plain(&'a str),
}

fn text<'a>(n: Node, src: &'a str) -> &'a str {
    src.get(n.byte_range()).unwrap_or("")
}

fn named(n: Node) -> Vec<Node> {
    let mut c = n.walk();
    n.named_children(&mut c).collect()
}

fn callee<'a>(call: Node<'a>, src: &'a str) -> Option<Callee<'a>> {
    let mut f = named(call).into_iter().next()?;
    if f.kind() == "instantiation_expression" {
        f = named(f).into_iter().next()?;
    }
    match f.kind() {
        "identifier" => Some(Callee::Plain(text(f, src))),
        "member_expression" | "null_aware_member_expression" => {
            let parts = named(f);
            let name = parts.last().filter(|n| n.kind() == "identifier")?;
            Some(Callee::Method {
                receiver: *parts.first()?,
                name: text(*name, src),
            })
        }
        _ => None,
    }
}

/// The last name of a possibly prefixed one: `fsp.RouteLink` is `RouteLink`.
fn last_name(s: &str) -> &str {
    s.rsplit('.').next().unwrap_or(s).trim()
}

fn arguments(call: Node) -> Option<Node> {
    named(call)
        .into_iter()
        .rev()
        .find(|n| n.kind() == "arguments")
}

/// The first argument that is not named, when it is a string literal.
fn first_positional(args: Node<'_>) -> Option<Node<'_>> {
    named(args)
        .into_iter()
        .find(|n| !matches!(n.kind(), "named_argument" | "comment"))
        .filter(|n| n.kind() == "string_literal")
}

/// The value of the named argument `label:`.
fn named_argument<'a>(args: Node<'a>, label: &str, src: &str) -> Option<Node<'a>> {
    named(args)
        .into_iter()
        .filter(|n| n.kind() == "named_argument")
        .find(|n| {
            named(*n).first().is_some_and(|l| {
                l.kind() == "label" && text(*l, src).trim_end_matches(':').trim() == label
            })
        })
        .and_then(|n| named(n).into_iter().last())
}

fn visit(node: Node, src: &str, out: &mut Vec<Site>) {
    match node.kind() {
        "call_expression" if !node.has_error() => call(node, src, out),
        "const_object_expression" if !node.has_error() => constructor(node, src, out),
        "cascade_call_expression" if !node.has_error() => cascade(node, src, out),
        _ => {}
    }
}

fn site(kind: SiteKind, lit: Node, call: Node, src: &str) -> Site {
    let (pieces, text) = read_literal(lit, src);
    Site {
        kind,
        pieces,
        text,
        span: Span {
            line: lit.start_position().row + 1,
            bytes: lit.byte_range(),
        },
        call_line: call.start_position().row + 1,
        end_line: lit.end_position().row + 1,
        ignored: false,
    }
}

fn call(node: Node, src: &str, out: &mut Vec<Site>) {
    let (Some(callee), Some(args)) = (callee(node, src), arguments(node)) else {
        return;
    };
    match callee {
        Callee::Method { receiver, name } => {
            if NAVIGATE.contains(&name)
                && let Some(lit) = first_positional(args)
            {
                out.push(site(SiteKind::Navigate, lit, node, src));
            }
            let owner = last_name(text(receiver, src));
            match (owner, name) {
                ("AppRoutes", "mount") => out.push(mount(args, node, src)),
                ("AppRoutes", "router") => initial_location(args, node, src, out),
                (_, "RouteLink") => route_link(args, node, src, out),
                _ => {}
            }
        }
        Callee::Plain("RouteLink") => route_link(args, node, src, out),
        Callee::Plain("GoRouter") => initial_location(args, node, src, out),
        Callee::Plain(_) => {}
    }
}

/// `const RouteLink(...)`.
fn constructor(node: Node, src: &str, out: &mut Vec<Site>) {
    let ty = named(node).into_iter().find(|n| n.kind() == "type");
    if ty.is_some_and(|t| last_name(text(t, src)) == "RouteLink")
        && let Some(args) = arguments(node)
    {
        route_link(args, node, src, out);
    }
}

/// `router..go('/x')`: the call is a cascade section's.
fn cascade(node: Node, src: &str, out: &mut Vec<Site>) {
    let parts = named(node);
    let Some(name) = parts.iter().find(|n| n.kind() == "identifier") else {
        return;
    };
    if NAVIGATE.contains(&text(*name, src))
        && let Some(lit) = arguments(node).and_then(first_positional)
    {
        out.push(site(SiteKind::Navigate, lit, node, src));
    }
}

fn route_link(args: Node, call: Node, src: &str, out: &mut Vec<Site>) {
    let Some(uri) = named_argument(args, "uri", src) else {
        return;
    };
    if uri.kind() != "call_expression" || uri.has_error() {
        return;
    }
    let is_parse = matches!(
        callee(uri, src),
        Some(Callee::Method { receiver, name: "parse" }) if last_name(text(receiver, src)) == "Uri"
    );
    if is_parse && let Some(lit) = arguments(uri).and_then(first_positional) {
        out.push(site(SiteKind::RouteLinkUri, lit, call, src));
    }
}

fn initial_location(args: Node, call: Node, src: &str, out: &mut Vec<Site>) {
    if let Some(lit) = named_argument(args, "initialLocation", src)
        && lit.kind() == "string_literal"
    {
        out.push(site(SiteKind::InitialLocation, lit, call, src));
    }
}

fn mount(args: Node, call: Node, src: &str) -> Site {
    let at = match named_argument(args, "at", src) {
        None => MountAt::Default,
        Some(v) if v.kind() == "string_literal" => MountAt::Literal(read_literal(v, src).0),
        Some(_) => MountAt::Unknown,
    };
    let line = call.start_position().row + 1;
    Site {
        kind: SiteKind::Mount(at),
        pieces: vec![],
        text: String::new(),
        span: Span {
            line,
            bytes: call.byte_range(),
        },
        call_line: line,
        end_line: call.end_position().row + 1,
        ignored: false,
    }
}

// --- String literals ----------------------------------------------------------------------

/// A `string_literal` as its pieces and its source text without the quotes. Adjacent literals
/// (`'/a' '/b'`) are one string.
fn read_literal(lit: Node, src: &str) -> (Vec<Piece>, String) {
    let mut pieces: Vec<Piece> = vec![];
    let mut shown = String::new();
    let mut push = |piece: Piece| match (pieces.last_mut(), piece) {
        (Some(Piece::Text(t)), Piece::Text(more)) => t.push_str(&more),
        (_, p) => pieces.push(p),
    };
    for part in named(lit) {
        let raw_text = text(part, src);
        let (inner, raw) = unquote(raw_text);
        shown.push_str(inner);
        if raw {
            push(Piece::Text(inner.to_string()));
            continue;
        }
        for child in named(part) {
            match child.kind() {
                k if k.starts_with("template_chars") => {
                    push(Piece::Text(text(child, src).to_string()));
                }
                "escape_sequence" => push(Piece::Text(unescape(text(child, src)))),
                _ => push(Piece::Hole),
            }
        }
    }
    (pieces, shown)
}

/// `'abc'`, `r'abc'`, `'''abc'''` without the quotes, and whether it was raw.
fn unquote(lit: &str) -> (&str, bool) {
    let (s, raw) = match lit.strip_prefix('r') {
        Some(rest) => (rest, true),
        None => (lit, false),
    };
    let quote = if s.len() >= 6 && (s.starts_with("'''") || s.starts_with("\"\"\"")) {
        3
    } else {
        1
    };
    let inner = s
        .get(quote..s.len().saturating_sub(quote))
        .unwrap_or_default();
    (inner, raw)
}

/// What a Dart escape stands for: `\n`, `\xHH`, `\uHHHH`, `\u{H...}`; any other `\c` is `c`.
fn unescape(esc: &str) -> String {
    let mut chars = esc.chars();
    chars.next();
    let Some(c) = chars.next() else {
        return String::new();
    };
    let digits: String = chars.collect();
    let code = |hex: &str| {
        u32::from_str_radix(hex.trim_matches(['{', '}']), 16)
            .ok()
            .and_then(char::from_u32)
    };
    match c {
        'n' => "\n".into(),
        't' => "\t".into(),
        'r' => "\r".into(),
        'b' => "\u{8}".into(),
        'f' => "\u{c}".into(),
        'v' => "\u{b}".into(),
        'x' | 'u' => code(&digits).map_or_else(|| format!("{c}{digits}"), String::from),
        other => other.to_string(),
    }
}

// --- Ignore comments ------------------------------------------------------------------------

/// `// fsp:ignore unknown_path` and `// fsp:ignore-file unknown_path`, found by text.
/// A false match can only silence a site, never report one.
struct Ignores {
    file: bool,
    /// `(line, alone)`: the 1-based line, and whether the comment is the only thing on it.
    lines: Vec<(usize, bool)>,
}

impl Ignores {
    fn read(src: &str) -> Ignores {
        let mut found = Ignores {
            file: false,
            lines: vec![],
        };
        for (i, line) in src.lines().enumerate() {
            let Some(slash) = line.find("//") else {
                continue;
            };
            let comment = &line[slash + 2..];
            if names_us(comment, "fsp:ignore-file") {
                found.file = true;
            } else if names_us(comment, "fsp:ignore") {
                found.lines.push((i + 1, line[..slash].trim().is_empty()));
            }
        }
        found
    }

    /// A comment on its own line silences the call below it (and a call that starts there); a
    /// comment after code silences what is on its line. Both reach into a multi-line call.
    fn silences(&self, s: &Site) -> bool {
        self.file
            || self.lines.iter().any(|&(line, alone)| {
                let from = if alone {
                    s.call_line.saturating_sub(1).max(1)
                } else {
                    s.call_line
                };
                (from..=s.end_line).contains(&line)
            })
    }
}

/// Whether `comment` has `key`, whitespace, then a list that includes [`ID`]. The list is the
/// words made of `a-z` and `_`, separated by spaces or commas, up to the first other word:
/// `fsp:ignore unknown_path -- the gift cards page is not built yet`.
fn names_us(comment: &str, key: &str) -> bool {
    let Some(at) = comment.find(key) else {
        return false;
    };
    let rest = &comment[at + key.len()..];
    if !rest.starts_with(char::is_whitespace) {
        return false;
    }
    rest.split(|c: char| c.is_whitespace() || c == ',')
        .filter(|w| !w.is_empty())
        .take_while(|w| w.chars().all(|c| c.is_ascii_lowercase() || c == '_'))
        .any(|w| w == ID)
}

// --- The route table --------------------------------------------------------------------------

/// The routes as `AppRoutes.matchUrl` tries them, for matching string paths.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Table {
    routes: Vec<Pattern>,
    /// The root's case setting: what compares the mount point, as `matchUrl` does.
    root_case_sensitive: bool,
}

#[derive(Debug, Clone, PartialEq)]
struct Pattern {
    parts: Vec<Part>,
    case_sensitive: bool,
}

#[derive(Debug, Clone, PartialEq)]
enum Part {
    /// Every spelling that reaches the segment (a localized folder has several).
    Static(Vec<String>),
    Dynamic,
    /// `$$rest` (one or more parts) or `$$$rest` (`optional`: none or more).
    Rest {
        optional: bool,
    },
}

impl Table {
    /// Every route (a page or a `redirect.dart`) of `app`. A `not_found.dart` adds none.
    pub fn new(app: &App) -> Table {
        let routes = app
            .routes
            .iter()
            .filter(|r| r.is_route())
            .map(|r| Pattern {
                case_sensitive: r.case_sensitive,
                parts: r
                    .url
                    .iter()
                    .enumerate()
                    .filter_map(|(i, s)| match s {
                        Seg::Static(s) => Some(Part::Static(
                            locale::at(&r.localized, i)
                                .map_or_else(|| vec![s.clone()], Localized::alternatives),
                        )),
                        Seg::Dynamic(_) => Some(Part::Dynamic),
                        Seg::CatchAll(_, optional) => Some(Part::Rest {
                            optional: *optional,
                        }),
                        Seg::Group(_) => None,
                    })
                    .collect(),
            })
            .collect();
        Table {
            routes,
            root_case_sensitive: app.routes.first().is_none_or(|r| r.case_sensitive),
        }
    }
}

fn same(a: &str, b: &str, case_sensitive: bool) -> bool {
    if case_sensitive {
        a == b
    } else {
        a.to_lowercase() == b.to_lowercase()
    }
}

impl Pattern {
    /// The parts of `path` that do not fit, or `None` when the lengths do not fit either. An
    /// empty list is a match (`AppRoutes.matchUrl`'s `_capture`).
    fn misfits(&self, path: &[String]) -> Option<Vec<usize>> {
        let mut bad = vec![];
        for (i, part) in self.parts.iter().enumerate() {
            match part {
                Part::Rest { optional } => {
                    return (path.len() > i || *optional).then_some(bad);
                }
                _ if i >= path.len() => return None,
                Part::Dynamic => {}
                Part::Static(spellings) => {
                    if !spellings
                        .iter()
                        .any(|s| same(s, &path[i], self.case_sensitive))
                    {
                        bad.push(i);
                    }
                }
            }
        }
        (path.len() == self.parts.len()).then_some(bad)
    }

    /// Whether a path that starts with `prefix` (and goes on in any way) could fit.
    fn starts_like(&self, prefix: &[String]) -> bool {
        for (i, want) in prefix.iter().enumerate() {
            match self.parts.get(i) {
                None => return false,
                Some(Part::Rest { .. }) => return true,
                Some(Part::Dynamic) => {}
                Some(Part::Static(spellings)) => {
                    if !spellings.iter().any(|s| same(s, want, self.case_sensitive)) {
                        return false;
                    }
                }
            }
        }
        true
    }
}

impl Table {
    fn matches(&self, path: &[String]) -> bool {
        self.routes
            .iter()
            .any(|p| p.misfits(path).is_some_and(|bad| bad.is_empty()))
    }

    /// The nearest spelling of the one static part that is wrong, as `(part index, spelling)`:
    /// a route that fits but for one static part, within a couple of typos.
    fn nearest(&self, path: &[String]) -> Option<(usize, String)> {
        let mut best: Option<(usize, usize, String)> = None;
        for pattern in &self.routes {
            let Some(bad) = pattern.misfits(path) else {
                continue;
            };
            let [i] = bad[..] else {
                continue;
            };
            let Part::Static(spellings) = &pattern.parts[i] else {
                continue;
            };
            let have = path[i].to_lowercase();
            for spelling in spellings {
                let d = distance(&have, &spelling.to_lowercase());
                if d <= 2
                    && d <= spelling.chars().count() / 3
                    && best.as_ref().is_none_or(|(b, ..)| d < *b)
                {
                    best = Some((d, i, spelling.clone()));
                }
            }
        }
        best.map(|(_, i, s)| (i, s))
    }
}

/// The Levenshtein distance between two strings, in characters.
fn distance(a: &str, b: &str) -> usize {
    let b: Vec<char> = b.chars().collect();
    let mut row: Vec<usize> = (0..=b.len()).collect();
    for (i, ca) in a.chars().enumerate() {
        let mut diagonal = row[0];
        row[0] = i + 1;
        for (j, cb) in b.iter().enumerate() {
            let above = row[j + 1];
            row[j + 1] = (above + 1)
                .min(row[j] + 1)
                .min(diagonal + usize::from(ca != *cb));
            diagonal = above;
        }
    }
    row[b.len()]
}

// --- Matching a path ----------------------------------------------------------------------

/// What to say about one site, if anything.
#[derive(Debug, PartialEq)]
enum Finding {
    /// A path with no hole that no route fits, and the nearest spelling if there is one.
    Unmatched {
        path: String,
        suggestion: Option<String>,
    },
    /// A path that interpolates, whose first complete segments no route starts with.
    NoRouteStarts { prefix: String, text: String },
}

impl Finding {
    fn message(&self) -> String {
        match self {
            Finding::Unmatched {
                path,
                suggestion: None,
            } => {
                format!("no route matches `{path}`, so it shows not-found [{ID}]")
            }
            Finding::Unmatched {
                path,
                suggestion: Some(s),
            } => format!(
                "no route matches `{path}`, so it shows not-found; did you mean `{s}`? [{ID}]"
            ),
            Finding::NoRouteStarts { prefix, text } => format!(
                "no route starts with `{prefix}`, so `{text}` shows not-found whatever it interpolates [{ID}]"
            ),
        }
    }
}

/// `%41` as `A`; `None` for a malformed escape or bytes that are not UTF-8 (`Uri.parse` throws
/// on the first, and the path is some other bug's).
fn decode(part: &str) -> Option<String> {
    let bytes = part.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = part.get(i + 1..i + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// The decoded, non-empty segments of `path`; `None` for one that cannot be read (a malformed
/// escape, a `.` or `..`, which `Uri.parse` resolves).
fn segments(path: &str) -> Option<Vec<String>> {
    let mut out = vec![];
    for raw in path.split('/').filter(|p| !p.is_empty()) {
        if raw == "." || raw == ".." {
            return None;
        }
        out.push(decode(raw)?);
    }
    Some(out)
}

/// `parts` below the mount point `base`; `None` when they are not under it.
fn below<'a>(parts: &'a [String], base: &[String], case_sensitive: bool) -> Option<&'a [String]> {
    if parts.len() < base.len() {
        return None;
    }
    base.iter()
        .zip(parts)
        .all(|(b, p)| same(b, p, case_sensitive))
        .then(|| &parts[base.len()..])
}

/// Looks at one site: `None` when it is fine, or cannot be judged.
fn judge(site: &Site, base: &[String], table: &Table) -> Option<Finding> {
    // The text before the first interpolation, and whether there is one.
    let mut lead = String::new();
    let mut hole = false;
    for p in &site.pieces {
        match p {
            Piece::Text(t) => lead.push_str(t),
            Piece::Hole => {
                hole = true;
                break;
            }
        }
    }
    if !lead.starts_with('/') || lead.starts_with("//") {
        return None;
    }
    let cut = lead.find(['?', '#']);
    if cut.is_none() && hole {
        return judge_prefix(site, &lead, base, table);
    }
    // Nothing after a `?` or `#` is checked, holes included.
    let path_end = cut.unwrap_or(lead.len());
    let parts = segments(&lead[..path_end])?;
    let below = below(&parts, base, table.root_case_sensitive)?;
    if table.matches(below) {
        return None;
    }
    let shown = if hole {
        site.text.clone()
    } else {
        lead.clone()
    };
    // With a hole after the `?`, `lead` is only the start of the literal: no suggestion.
    let nearest = if hole { None } else { table.nearest(below) };
    let suggestion = nearest.map(|(i, spelling)| {
        let mut raw: Vec<&str> = lead[..path_end].split('/').collect();
        let at = raw
            .iter()
            .enumerate()
            .filter(|(_, p)| !p.is_empty())
            .nth(base.len() + i)
            .map(|(k, _)| k);
        if let Some(k) = at {
            raw[k] = &spelling;
        }
        format!("{}{}", raw.join("/"), &lead[path_end..])
    });
    Some(Finding::Unmatched {
        path: shown,
        suggestion,
    })
}

/// A path with an interpolation: the complete segments before the first one must be the start
/// of some route. A hole can be empty or hold `/`, so nothing after it is checked.
fn judge_prefix(site: &Site, lead: &str, base: &[String], table: &Table) -> Option<Finding> {
    let (before, _) = lead.rsplit_once('/')?;
    let parts = segments(before)?;
    if parts.len() <= base.len() {
        return None;
    }
    let below = below(&parts, base, table.root_case_sensitive)?;
    if table.routes.iter().any(|p| p.starts_like(below)) {
        return None;
    }
    Some(Finding::NoRouteStarts {
        prefix: format!("{before}/"),
        text: site.text.clone(),
    })
}

// --- The mount point ------------------------------------------------------------------------

/// Where the tree is mounted, from the `AppRoutes.mount(at:)` calls in `lib/`: `/` without any,
/// the one `at:` literal all of them share, and `None` when it cannot be known (an `at:` that is
/// not a literal, or two different ones).
fn mount_point(all: &[(String, Rc<Vec<Site>>)]) -> Option<Vec<String>> {
    let mut found: Option<Vec<String>> = None;
    for site in all.iter().flat_map(|(_, s)| s.iter()) {
        let SiteKind::Mount(at) = &site.kind else {
            continue;
        };
        let parts: Vec<String> = match at {
            MountAt::Default => vec![],
            MountAt::Unknown => return None,
            MountAt::Literal(pieces) => match pieces.as_slice() {
                [] => vec![],
                [Piece::Text(t)] => t
                    .split('/')
                    .filter(|p| !p.is_empty())
                    .map(String::from)
                    .collect(),
                _ => return None,
            },
        };
        if found.as_ref().is_some_and(|f| *f != parts) {
            return None;
        }
        found = Some(parts);
    }
    Some(found.unwrap_or_default())
}

// --- Walking `lib/` -------------------------------------------------------------------------------

/// The parsed sites of each file, kept by `fsp watch` between runs: path relative to the
/// project, the source they were read from, the sites. A file is parsed again only when its
/// source changed.
#[derive(Default)]
pub struct Sites(HashMap<String, (String, Rc<Vec<Site>>)>);

#[cfg(test)]
impl Sites {
    /// How many files are kept.
    pub fn len(&self) -> usize {
        self.0.len()
    }
}

/// Every Dart file under `lib/` the lint reads, relative to the project, in a stable order:
/// not the generated ones, and not the contents of a folder that starts with `.`.
fn lib_files(project: &Path, cfg: &Config) -> Vec<String> {
    let mut out = vec![];
    let mut dirs = vec![String::from("lib")];
    while let Some(dir) = dirs.pop() {
        let Ok(read) = fs::read_dir(project.join(&dir)) else {
            continue;
        };
        let mut entries: Vec<(String, bool)> = read
            .filter_map(Result::ok)
            .filter_map(|e| {
                let kind = e.file_type().ok()?;
                (!kind.is_symlink())
                    .then(|| (e.file_name().to_string_lossy().into_owned(), kind.is_dir()))
            })
            .collect();
        entries.sort();
        for (name, is_dir) in entries {
            let rel = format!("{dir}/{name}");
            if is_dir {
                if !name.starts_with('.') {
                    dirs.push(rel);
                }
            } else if name.ends_with(".dart")
                && !name.ends_with(".g.dart")
                && rel != cfg.output
                && Some(&rel) != cfg.output_manifest.as_ref()
            {
                out.push(rel);
            }
        }
    }
    out.sort();
    out
}

/// Runs the lints the config asks for over `lib/`, against `table`.
pub fn check(project: &Path, cfg: &Config, table: &Table, kept: &mut Sites) -> Diags {
    let mut diags = Diags::default();
    let level = match cfg.lints.unknown_path {
        LintLevel::Off => return diags,
        LintLevel::Warning => Level::Warning,
        LintLevel::Error => Level::Error,
    };
    let mut seen: HashSet<String> = HashSet::new();
    let mut all: Vec<(String, Rc<Vec<Site>>)> = vec![];
    for rel in lib_files(project, cfg) {
        let Ok(src) = fs::read_to_string(project.join(&rel)) else {
            continue;
        };
        if !MARKERS.iter().any(|m| src.contains(m)) {
            continue;
        }
        let found = match kept.0.get(&rel) {
            Some((was, found)) if *was == src => Rc::clone(found),
            _ => {
                let found = Rc::new(sites(&src));
                kept.0.insert(rel.clone(), (src, Rc::clone(&found)));
                found
            }
        };
        seen.insert(rel.clone());
        all.push((rel, found));
    }
    kept.0.retain(|rel, _| seen.contains(rel));
    let Some(base) = mount_point(&all) else {
        return diags;
    };
    let in_app = format!("{}/", cfg.app_dir);
    for (rel, found) in &all {
        let (base_of, shown) = match rel.strip_prefix(&in_app) {
            Some(inside) => (Base::App, inside),
            None => (Base::Project, rel.as_str()),
        };
        for s in found.iter().filter(|s| !s.ignored) {
            if matches!(s.kind, SiteKind::Mount(_)) {
                continue;
            }
            if let Some(f) = judge(s, &base, table) {
                diags.add(level.clone(), base_of, shown, Some(&s.span), f.message());
            }
        }
    }
    diags
}
