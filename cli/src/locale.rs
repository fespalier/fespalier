//! Localized paths: `const paths = {'fr': 'produits', 'de': 'produkte'};` in a folder's
//! `route.dart` gives that folder's own static segment more spellings, so `products/` also
//! answers `/produits` and `/produkte` while the typed route, the page and the data stay single.
//!
//! In go_router a localized segment is a path parameter with an alternation of its own:
//! `:_l1(products|produits|produkte)`, where `1` is the segment's place in the URL. It is one
//! `GoRoute` whatever the spelling, so nested routes, the page key, restoration ids and a tab's
//! `StatefulShellBranch` see one route; the first alternative is always the folder's name.
//!
//! This module reads and checks the declaration, spells the paths, and reports URLs that two
//! routes would both serve. Everything else (the `GoRoute`s, the matchers, the manifest) asks
//! it for the spellings.

use std::collections::BTreeMap;

use crate::dart::{Module, Span};
use crate::diag::Diags;
use crate::resolve::{App, Route};
use crate::scan::{Kind, Seg};

/// The name of the path parameter that carries a localized segment: `_l1` for the second segment
/// of the URL. Segments can't start with `_`, so it never clashes with one, and it is unique in a
/// path (go_router refuses a parameter name used twice down one branch).
fn param(at: usize) -> String {
    format!("_l{at}")
}

/// One spelling of a segment in one locale.
#[derive(Debug, Clone, PartialEq)]
pub struct Spelling {
    /// The locale tag as written: `fr`, `pt-BR`.
    pub locale: String,
    pub path: String,
    /// The value in `route.dart`, for a diagnostic that points at it.
    pub span: Span,
}

/// The `paths` of one folder's `route.dart`: the other spellings of its own segment.
#[derive(Debug, Clone, PartialEq)]
pub struct Localized {
    /// The segment's place in the route's URL (`(group)` folders add none).
    pub at: usize,
    /// The folder's name: the canonical spelling, and what a locale without an entry gets.
    pub canonical: String,
    /// The `route.dart` it is declared in, relative to the app folder.
    pub file: String,
    /// In the order the map declares them.
    pub spellings: Vec<Spelling>,
}

impl Localized {
    /// Every spelling that reaches the segment, the canonical one first, each once.
    pub fn alternatives(&self) -> Vec<String> {
        let mut out = vec![self.canonical.clone()];
        for s in &self.spellings {
            if !out.contains(&s.path) {
                out.push(s.path.clone());
            }
        }
        out
    }

    /// How `locale` spells the segment; the canonical spelling when it has no entry. A tag
    /// with a region falls back to its language (`fr-CA` to `fr`), like the runtime's
    /// `localizedSegment`.
    pub fn spelled(&self, locale: &str) -> &str {
        let find = |tag: &str| self.spellings.iter().find(|s| same_tag(&s.locale, tag));
        let base = locale.split(['-', '_']).next().unwrap_or(locale);
        find(locale).or_else(|| find(base)).map_or(self.canonical.as_str(), |s| s.path.as_str())
    }

    /// The segment as go_router reads it: a parameter that matches any of the spellings.
    /// Only `.` needs escaping: a spelling is limited to letters, digits and `-_.~`.
    pub fn go_router_part(&self) -> String {
        let alts: Vec<String> = self.alternatives().iter().map(|a| a.replace('.', "\\.")).collect();
        format!(":{}({})", param(self.at), alts.join("|"))
    }

    /// The segment as a `RouteMatcher` or not-found prefix part: the alternatives joined by
    /// `|`, which no segment can contain.
    pub fn matcher_part(&self) -> String {
        self.alternatives().join("|")
    }
}

fn same_tag(a: &str, b: &str) -> bool {
    a.replace('_', "-").eq_ignore_ascii_case(&b.replace('_', "-"))
}

/// The entry of `localized` for the segment at `at`.
pub fn at(localized: &[Localized], at: usize) -> Option<&Localized> {
    localized.iter().find(|l| l.at == at)
}

/// The locale tags a route's segments have spellings for, in the order they are first declared.
pub fn locales(localized: &[Localized]) -> Vec<String> {
    let mut out: Vec<String> = vec![];
    for s in localized.iter().flat_map(|l| &l.spellings) {
        if !out.iter().any(|o| same_tag(o, &s.locale)) {
            out.push(s.locale.clone());
        }
    }
    out
}

/// The pattern of a URL in `locale` (`/produits/:id`), each level falling back to its
/// canonical spelling where `locale` has no entry.
pub fn pattern_in(url: &[Seg], localized: &[Localized], locale: &str) -> String {
    pattern_with(url, |i, s| at(localized, i).map_or(s.to_string(), |l| l.spelled(locale).to_string()))
}

/// `resolve::pattern`, with `spell` giving each static segment (by its place in `url`).
fn pattern_with(url: &[Seg], spell: impl Fn(usize, &str) -> String) -> String {
    let parts: Vec<String> = url
        .iter()
        .enumerate()
        .filter_map(|(i, s)| match s {
            Seg::Static(s) => Some(spell(i, s)),
            Seg::Dynamic(n) => Some(format!(":{n}")),
            Seg::CatchAll(n, optional) => Some(format!("*{n}{}", if *optional { "?" } else { "" })),
            Seg::Group(_) => None,
        })
        .collect();
    format!("/{}", parts.join("/"))
}

/// A path pattern without its localized segments' parameters: `:_l0(products|produits)` is
/// `products`, its first (canonical) alternative.
pub fn canonical_path(path: &str) -> String {
    let mut out = String::new();
    let mut rest = path;
    while let Some(i) = rest.find(":_l") {
        out.push_str(&rest[..i]);
        let tail = &rest[i + 3..];
        let digits = tail.chars().take_while(char::is_ascii_digit).count();
        match tail[digits..].strip_prefix('(').and_then(|g| g.find(')').map(|end| &g[..end])) {
            Some(group) if digits > 0 => {
                out.push_str(&group.split('|').next().unwrap_or_default().replace("\\.", "."));
                let skip = ":_l".len() + digits + 1 + group.len() + 1;
                rest = &rest[i + skip..];
            }
            _ => {
                out.push_str(":_l");
                rest = tail;
            }
        }
    }
    out.push_str(rest);
    out
}

/// Whether a path pattern has a parameter of a route's own (`:id`, `:rest(.+)`), not counting
/// the parameters that localized segments are made of.
pub fn has_params(path: &str) -> bool {
    canonical_path(path).contains(':')
}

/// Whether a path pattern has a localized segment.
pub fn is_localized(path: &str) -> bool {
    path.contains(":_l")
}

// --- Reading route.dart ------------------------------------------------------

/// A locale tag: a language (`fr`), then optional subtags (`pt-BR`, `zh_Hant`).
fn valid_tag(tag: &str) -> bool {
    let mut parts = tag.split(['-', '_']);
    let language = parts.next().unwrap_or_default();
    (2..=3).contains(&language.len())
        && language.chars().all(|c| c.is_ascii_alphabetic())
        && parts.all(|p| (1..=8).contains(&p.len()) && p.chars().all(|c| c.is_ascii_alphanumeric()))
}

/// What a folder name can be (`scan::parse_segment`): one URL segment of plain characters.
fn valid_spelling(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '~')) && s != "." && s != ".."
}

/// `const paths = {'fr': 'produits', 'de': 'produkte'};` in the `route.dart` at `file`, for a
/// folder whose own segment is `seg` (`None` for the app folder, which has none), at place `at`
/// in its URL. Errors point at the entry at fault.
pub fn read(m: &Module, file: &str, seg: Option<&Seg>, at: usize, diags: &mut Diags) -> Option<Localized> {
    let mut found = m.variables.iter().filter(|v| v.name == "paths");
    let v = found.next()?;
    if let Some(again) = found.next() {
        diags.error(file, Some(&again.span), "`paths` is declared twice");
    }
    let canonical = match seg {
        Some(Seg::Static(s)) => s.clone(),
        other => {
            let why = match other {
                Some(Seg::Dynamic(n)) => format!("`${n}` is a dynamic segment: it takes whatever the URL has, so there is no word to spell"),
                Some(Seg::CatchAll(n, _)) => format!("`$${n}` is a catch-all: it takes whatever is left of the URL, so there is no word to spell"),
                Some(Seg::Group(g)) => format!("`({g})` is a group: it adds nothing to the URL, so there is no word to spell"),
                _ => "the app folder has no URL segment of its own".to_string(),
            };
            diags.error(file, Some(&v.span), format!("`paths` gives a static folder's name more spellings, but {why}; put `paths` in the route.dart of the folder that has the word"));
            return None;
        }
    };
    let Some(pairs) = &v.pairs else {
        let msg = "`paths` must be a map literal from a locale tag to one spelling, e.g. `const paths = {'fr': 'produits', 'de': 'produkte'};`: fsp reads it from the source, it doesn't run it";
        diags.error(file, Some(&v.span), msg);
        return None;
    };
    let mut spellings: Vec<Spelling> = vec![];
    let mut ok = true;
    for p in pairs {
        let Some(locale) = &p.key else {
            diags.error(file, Some(&p.key_span), "a key of `paths` must be a string literal naming a locale, e.g. `'fr'`: fsp reads it from the source");
            ok = false;
            continue;
        };
        let Some(path) = &p.value else {
            diags.error(file, Some(&p.value_span), "a value of `paths` must be a plain string literal, e.g. `'produits'`: fsp reads it from the source");
            ok = false;
            continue;
        };
        if !valid_tag(locale) {
            let msg = format!("`{locale}` isn't a locale tag: use a language, with a region if you like, e.g. `'fr'` or `'pt-BR'`");
            diags.error(file, Some(&p.key_span), msg);
            ok = false;
        } else if let Some(first) = spellings.iter().find(|s| same_tag(&s.locale, locale)) {
            let msg = format!("`paths` has `{locale}` twice (the first is on line {})", first.span.line);
            diags.error(file, Some(&p.key_span), msg);
            ok = false;
        }
        if !valid_spelling(path) {
            let why = if path.contains('/') {
                "it is one URL segment, so it has no `/` in it"
            } else if path.is_empty() {
                "it can't be empty"
            } else {
                "use a-z, 0-9, - _ . ~ like a folder name does (a spelling with other letters would have to be percent-encoded, which isn't supported yet: write it without accents)"
            };
            let msg = format!("`{path}` is not a valid URL segment for `{locale}`: {why}");
            diags.error(file, Some(&p.value_span), msg);
            ok = false;
        }
        spellings.push(Spelling { locale: locale.clone(), path: path.clone(), span: p.value_span.clone() });
    }
    if ok && spellings.is_empty() {
        diags.warn(file, Some(&v.span), "`paths` is empty, so it adds no spelling");
    }
    ok.then_some(Localized { at, canonical, file: file.to_string(), spellings })
}

// --- Colliding URLs ------------------------------------------------------------

/// One way of spelling a route's URL: each localized segment (by index into its `localized`)
/// in one of its spellings; `None` is the canonical one.
type Combo = Vec<Option<usize>>;

/// Every URL a route serves, spelled out: (its pattern, the spelling of each localized segment).
/// Capped, so a folder tree with many spellings on every level can't make this explode.
fn served(r: &Route) -> Vec<(String, Combo)> {
    const CAP: usize = 4096;
    let mut combos: Vec<Combo> = vec![vec![]];
    for l in &r.localized {
        let mut next = vec![];
        for c in &combos {
            for choice in std::iter::once(None).chain((0..l.spellings.len()).map(Some)) {
                let mut c = c.clone();
                c.push(choice);
                next.push(c);
            }
        }
        combos = next;
        combos.truncate(CAP);
    }
    let mut out: Vec<(String, Combo)> = vec![];
    for c in combos {
        let path = pattern_with(&r.url, |i, canonical| match r.localized.iter().position(|l| l.at == i) {
            Some(k) => c[k].map_or(canonical.to_string(), |s| r.localized[k].spellings[s].path.clone()),
            None => canonical.to_string(),
        });
        // Two spellings that agree (`fr: 'menu'` and `de: 'menu'`) are one URL.
        if !out.iter().any(|(p, _)| *p == path) {
            out.push((path, c));
        }
    }
    out
}

/// The first spelling in `combo` that isn't the canonical one: where a collision comes from.
fn culprit<'r>(r: &'r Route, combo: &Combo) -> Option<(&'r Localized, &'r Spelling)> {
    combo.iter().enumerate().find_map(|(k, choice)| {
        let l = &r.localized[k];
        choice.map(|s| (l, &l.spellings[s])).filter(|(l, s)| s.path != l.canonical)
    })
}

/// A URL that two routes serve, when a localized spelling is what brings them together: it is
/// an error at the spelling in its `route.dart` and at the route it collides with (the other
/// spelling, when that is localized too). Two routes that collide by their folder names alone
/// are reported by the resolver already.
pub fn check_collisions(app: &App, diags: &mut Diags) {
    let mut urls: BTreeMap<String, Vec<(usize, Combo)>> = BTreeMap::new();
    for (id, r) in app.routes.iter().enumerate().filter(|(_, r)| r.is_route() && !r.localized.is_empty()) {
        for (path, combo) in served(r) {
            urls.entry(path).or_default().push((id, combo));
        }
    }
    // Routes with no localized segment can be on the other side of a collision too.
    for (id, r) in app.routes.iter().enumerate().filter(|(_, r)| r.is_route() && r.localized.is_empty()) {
        let path = pattern_with(&r.url, |_, s| s.to_string());
        if let Some(members) = urls.get_mut(&path) {
            members.push((id, vec![]));
        }
    }
    for (path, members) in &urls {
        for (i, (a, ca)) in members.iter().enumerate() {
            for (b, cb) in &members[i + 1..] {
                if a == b {
                    continue;
                }
                let (ra, rb) = (&app.routes[*a], &app.routes[*b]);
                let (ua, ub) = (culprit(ra, ca), culprit(rb, cb));
                if ua.is_none() && ub.is_none() {
                    continue;
                }
                report(path, (ra, ua), (rb, ub), diags);
                report(path, (rb, ub), (ra, ua), diags);
            }
        }
    }
}

type Side<'r> = (&'r Route, Option<(&'r Localized, &'r Spelling)>);

/// How a diagnostic names the other route: its page, or the spelling that reaches it.
fn describe(other: &Side) -> String {
    match other.1 {
        Some((l, s)) => format!("{} (`{}: '{}'` in {})", page_file(other.0), s.locale, s.path, l.file),
        None => page_file(other.0),
    }
}

fn page_file(r: &Route) -> String {
    crate::emit::rel(r, if r.page.is_some() { Kind::Page } else { Kind::Redirect })
}

/// The diagnostic for `me`: at its spelling when it has one, else at its page.
fn report(path: &str, me: Side, other: Side, diags: &mut Diags) {
    match me.1 {
        Some((l, s)) => {
            let msg = format!(
                "`{}: '{}'` makes {path}, which {} serves too; rename the spelling, or the folder it collides with",
                s.locale,
                s.path,
                describe(&other)
            );
            diags.error(&l.file, Some(&s.span), msg);
        }
        None => {
            let (l, s) = other.1.expect("a collision has a localized side");
            let msg = format!(
                "{path} is also reached through `{}: '{}'` in {}:{}; rename the spelling, or this folder",
                s.locale, s.path, l.file, s.span.line
            );
            diags.error(&page_file(me.0), me.0.page_span.as_ref(), msg);
        }
    }
}
