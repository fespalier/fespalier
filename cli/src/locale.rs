//! Localized paths: `const paths = {'fr': 'produits', 'de': 'produkte'};` in a folder's
//! `route.dart` gives that folder's own static segment more spellings, so `products/` also
//! answers `/produits` and `/produkte` while the typed route, the page and the data stay single.
//!
//! In `go_router` a localized segment is a path parameter with an alternation of its own:
//! `:_l1(products|produits|produkte)`, where `1` is the segment's place in the URL. It is one
//! `GoRoute` whatever the spelling, so nested routes, the page key, restoration ids and a tab's
//! `StatefulShellBranch` see one route; the first alternative is always the folder's name.
//!
//! This module reads and checks the declaration, spells the paths, and reports URLs that two
//! routes would both serve. Everything else (the `GoRoute`s, the matchers, the manifest) asks
//! it for the spellings.

#![allow(
    clippy::expect_used,
    reason = "a collision always has a localized side; the expect states that invariant"
)]

use std::collections::BTreeMap;

use crate::dart::{Module, Span};
use crate::diag::Diags;
use crate::resolve::{App, Route};
use crate::scan::{Kind, Seg};

/// The name of the path parameter that carries a localized segment: `_l1` for the second segment
/// of the URL. Segments can't start with `_`, so it never clashes with one, and it is unique in a
/// path (`go_router` refuses a parameter name used twice down one branch).
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
        find(locale)
            .or_else(|| find(base))
            .map_or(self.canonical.as_str(), |s| s.path.as_str())
    }

    /// The segment as `go_router` reads it: a parameter that matches any of the spellings.
    /// `go_router` matches the percent-encoded path (`Uri.path`), so a spelling with letters
    /// beyond ASCII goes in encoded (`%C3%BCber`), and `.` is escaped: nothing else in a
    /// spelling is special in a regular expression.
    pub fn go_router_part(&self) -> String {
        let alts: Vec<String> = self
            .alternatives()
            .iter()
            .map(|a| percent_encode(a).replace('.', "\\."))
            .collect();
        format!(":{}({})", param(self.at), alts.join("|"))
    }

    /// The segment as a `RouteMatcher` or not-found prefix part: the alternatives joined by
    /// `|`, which no segment can contain. These compare with decoded path segments, so
    /// they are spelled as written.
    pub fn matcher_part(&self) -> String {
        self.alternatives().join("|")
    }
}

/// A segment as `Uri` writes it: each byte of a non-ASCII character as `%XX` (upper case), the
/// characters a spelling may have otherwise as they are.
pub fn percent_encode(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars() {
        if c.is_ascii() {
            out.push(c);
        } else {
            let mut buf = [0; 4];
            for b in c.encode_utf8(&mut buf).bytes() {
                out.push_str(&format!("%{b:02X}"));
            }
        }
    }
    out
}

fn same_tag(a: &str, b: &str) -> bool {
    a.replace('_', "-")
        .eq_ignore_ascii_case(&b.replace('_', "-"))
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
    pattern_with(url, |i, s| {
        at(localized, i).map_or(s.to_string(), |l| l.spelled(locale).to_string())
    })
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
        match tail[digits..]
            .strip_prefix('(')
            .and_then(|g| g.find(')').map(|end| &g[..end]))
        {
            Some(group) if digits > 0 => {
                out.push_str(
                    &group
                        .split('|')
                        .next()
                        .unwrap_or_default()
                        .replace("\\.", "."),
                );
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

/// One URL segment: ASCII letters, digits and `-_.~` (a folder name's characters), and any
/// other letter or symbol beyond ASCII (`über`, `продукты`), which is matched percent-encoded.
/// Not `/ ? # %`, nor anything that would be special in a path, a regular expression or the
/// generated Dart, nor whitespace or control characters.
fn valid_spelling(s: &str) -> bool {
    let char_ok = |c: char| {
        if c.is_ascii() {
            c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '~')
        } else {
            !c.is_whitespace() && !c.is_control()
        }
    };
    !s.is_empty() && s.chars().all(char_ok) && s != "." && s != ".."
}

/// `const paths = {'fr': 'produits', 'de': 'produkte'};` in the `route.dart` at `file`, for a
/// folder whose own segment is `seg` (`None` for the app folder, which has none), at place `at`
/// in its URL. Errors point at the entry at fault.
pub fn read(
    m: &Module,
    file: &str,
    seg: Option<&Seg>,
    at: usize,
    diags: &mut Diags,
) -> Option<Localized> {
    let mut found = m.variables.iter().filter(|v| v.name == "paths");
    let v = found.next()?;
    if let Some(again) = found.next() {
        diags.error(file, Some(&again.span), "`paths` is declared twice");
    }
    let canonical = match seg {
        Some(Seg::Static(s)) => s.clone(),
        other => {
            let why = match other {
                Some(Seg::Dynamic(n)) => format!(
                    "`${n}` is a dynamic segment: it takes whatever the URL has, so there is no word to spell"
                ),
                Some(Seg::CatchAll(n, _)) => format!(
                    "`$${n}` is a catch-all: it takes whatever is left of the URL, so there is no word to spell"
                ),
                Some(Seg::Group(g)) => format!(
                    "`({g})` is a group: it adds nothing to the URL, so there is no word to spell"
                ),
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
    // An entry with a problem is reported and left out; the ones that read are kept, so a
    // collision between them is still found while the rest of the file is being fixed.
    let mut spellings: Vec<Spelling> = vec![];
    for p in pairs {
        let Some(locale) = &p.key else {
            diags.error(file, Some(&p.key_span), "a key of `paths` must be a string literal naming a locale, e.g. `'fr'`: fsp reads it from the source");
            continue;
        };
        let Some(path) = &p.value else {
            diags.error(file, Some(&p.value_span), "a value of `paths` must be a plain string literal, e.g. `'produits'`: fsp reads it from the source");
            continue;
        };
        let mut ok = true;
        if !valid_tag(locale) {
            let msg = format!(
                "`{locale}` isn't a locale tag: use a language, with a region if you like, e.g. `'fr'` or `'pt-BR'`"
            );
            diags.error(file, Some(&p.key_span), msg);
            ok = false;
        } else if let Some(first) = spellings.iter().find(|s| same_tag(&s.locale, locale)) {
            let msg = format!(
                "`paths` has `{locale}` twice (the first is on line {})",
                first.span.line
            );
            diags.error(file, Some(&p.key_span), msg);
            ok = false;
        }
        if !valid_spelling(path) {
            let why = if path.contains('/') {
                "it is one URL segment, so it has no `/` in it"
            } else if path.is_empty() {
                "it can't be empty"
            } else {
                "it may have letters (accented or not), digits and - _ . ~, but no `?`, `#`, `%`, `:`, `|`, quotes, brackets, `$`, `\\`, whitespace or control characters"
            };
            let msg = format!("`{path}` is not a valid URL segment for `{locale}`: {why}");
            diags.error(file, Some(&p.value_span), msg);
            ok = false;
        }
        if ok {
            spellings.push(Spelling {
                locale: locale.clone(),
                path: path.clone(),
                span: p.value_span.clone(),
            });
        }
    }
    if pairs.is_empty() {
        diags.warn(
            file,
            Some(&v.span),
            "`paths` is empty, so it adds no spelling",
        );
    }
    Some(Localized {
        at,
        canonical,
        file: file.to_string(),
        spellings,
    })
}

// --- Colliding URLs ------------------------------------------------------------

/// One way of spelling a URL: each localized segment (by index into its `localized`) in one
/// of its spellings; `None` is the canonical one.
type Combo = Vec<Option<usize>>;

/// What can collide: a route's page (or redirect), or a `not_found.dart`, at a URL.
struct Item<'a> {
    url: &'a [Seg],
    localized: &'a [Localized],
    /// The file a diagnostic names, relative to the app folder.
    file: String,
    /// Where in that file: the class name of a page; none for a `not_found.dart`.
    span: Option<&'a Span>,
}

/// Every URL an item serves, spelled out: (its pattern, the spelling of each localized
/// segment). Capped, so a tree with many spellings on every level can't make this explode.
fn served(item: &Item) -> Vec<(String, Combo)> {
    const CAP: usize = 4096;
    let mut combos: Vec<Combo> = vec![vec![]];
    for l in item.localized {
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
        let path = pattern_with(item.url, |i, canonical| {
            match item.localized.iter().position(|l| l.at == i) {
                Some(k) => c[k].map_or(canonical.to_string(), |s| {
                    item.localized[k].spellings[s].path.clone()
                }),
                None => canonical.to_string(),
            }
        });
        // Two spellings that agree (`fr: 'menu'` and `de: 'menu'`) are one URL.
        if !out.iter().any(|(p, _)| *p == path) {
            out.push((path, c));
        }
    }
    out
}

/// The first spelling in `combo` that isn't the canonical one: where a collision comes from.
fn culprit<'a>(item: &Item<'a>, combo: &Combo) -> Option<(&'a Localized, &'a Spelling)> {
    combo.iter().enumerate().find_map(|(k, choice)| {
        let l: &'a Localized = &item.localized[k];
        choice
            .map(|s| (l, &l.spellings[s]))
            .filter(|(l, s)| s.path != l.canonical)
    })
}

/// A URL that two routes (or two `not_found.dart` files) serve, when a localized spelling is
/// what brings them together: an error at the spelling in its `route.dart` and at the other
/// file (at its spelling, when that is localized too). Two that collide by their folder names
/// alone are reported by the resolver already.
pub fn check_collisions(app: &App, diags: &mut Diags) {
    // Pages and redirects are compared among themselves, and so are the not_found.dart files:
    // a not_found.dart and a page at one URL are not a clash.
    let routes: Vec<Item> = app
        .routes
        .iter()
        .filter(|r| r.is_route())
        .map(|r| Item {
            url: &r.url,
            localized: &r.localized,
            file: page_file(r),
            span: r.page_span.as_ref(),
        })
        .collect();
    let not_founds: Vec<Item> = app
        .not_founds
        .iter()
        .map(|n| Item {
            url: &n.url,
            localized: &n.localized,
            file: n.file.clone(),
            span: None,
        })
        .collect();
    for items in [routes, not_founds] {
        let mut urls: BTreeMap<String, Vec<(usize, Combo)>> = BTreeMap::new();
        for (i, item) in items
            .iter()
            .enumerate()
            .filter(|(_, it)| !it.localized.is_empty())
        {
            for (path, combo) in served(item) {
                urls.entry(path).or_default().push((i, combo));
            }
        }
        // Items with no localized segment can be on the other side of a collision too.
        for (i, item) in items
            .iter()
            .enumerate()
            .filter(|(_, it)| it.localized.is_empty())
        {
            if let Some(members) = urls.get_mut(&pattern_with(item.url, |_, s| s.to_string())) {
                members.push((i, vec![]));
            }
        }
        for (path, members) in &urls {
            for (n, (a, ca)) in members.iter().enumerate() {
                for (b, cb) in &members[n + 1..] {
                    if a == b {
                        continue;
                    }
                    let (ia, ib) = (&items[*a], &items[*b]);
                    let (ua, ub) = (culprit(ia, ca), culprit(ib, cb));
                    if ua.is_none() && ub.is_none() {
                        continue;
                    }
                    report(path, (ia, ua), (ib, ub), diags);
                    report(path, (ib, ub), (ia, ua), diags);
                }
            }
        }
    }
}

type Side<'r, 'a> = (&'r Item<'a>, Option<(&'a Localized, &'a Spelling)>);

/// How a diagnostic names the other file: itself, or the spelling that reaches it.
fn describe(other: &Side) -> String {
    match other.1 {
        Some((l, s)) => format!(
            "{} (`{}: '{}'` in {})",
            other.0.file, s.locale, s.path, l.file
        ),
        None => other.0.file.clone(),
    }
}

fn page_file(r: &Route) -> String {
    crate::emit::rel(
        r,
        if r.page.is_some() {
            Kind::Page
        } else {
            Kind::Redirect
        },
    )
}

/// The diagnostic for `me`: at its spelling when it has one, else at its own file.
fn report(path: &str, me: Side, other: Side, diags: &mut Diags) {
    if let Some((l, s)) = me.1 {
        let msg = format!(
            "`{}: '{}'` makes {path}, which {} serves too; rename the spelling, or the folder it collides with",
            s.locale,
            s.path,
            describe(&other)
        );
        diags.error(&l.file, Some(&s.span), msg);
    } else {
        let (l, s) = other.1.expect("a collision has a localized side");
        let msg = format!(
            "{path} is also reached through `{}: '{}'` in {}:{}; rename the spelling, or this folder",
            s.locale, s.path, l.file, s.span.line
        );
        diags.error(&me.0.file, me.0.span, msg);
    }
}
