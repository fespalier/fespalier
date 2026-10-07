//! `fsp links`: App Links, Universal Links and a sitemap, written from the route tree.
//!
//! The URLs the app opens are the routes' paths, so the lists the platforms want are derived
//! from them instead of kept by hand:
//!
//! - **Android**: `<intent-filter android:autoVerify="true">` elements (one per domain, and one
//!   for a custom scheme) to paste into the main activity of `AndroidManifest.xml`, which `fsp`
//!   never edits, and `assetlinks.json` (a statement per app).
//! - **iOS**: `apple-app-site-association` (`components`, every app id in `appIDs`), the
//!   `applinks:` entitlement entries and, for a custom scheme, the `CFBundleURLTypes` entry.
//!
//! Since 0.11.0 the apps are the flat keys' one app or the `flavors:` of the pubspec, a scheme
//! can be written without a host (`scheme_host: false`: `myshop:///orders/2`, which the router
//! matches on its path alone) and `paths:` lists what the platforms open instead of every
//! linkable route ([`warnings`] tells where the two disagree).
//! - **Web**: `sitemap.xml` with every static route as an absolute URL on the first domain, and
//!   `hreflang` alternates from the locale spellings of a [localized](crate::locale) path.
//!
//! Everything is a function of the tree and the pubspec: stable order, no dates, so `--check`
//! can compare the files on disk byte for byte.
//!
//! A route is a [`Link`]: its path as [`Piece`]s per spelling. A `$dynamic` segment is
//! [`Piece::Any`], a catch-all is [`Piece::Rest`], and each platform spells those its own way
//! ([`android_paths`], [`aasa_paths`]). A route in a folder with `const linkable = false;` is
//! left out of every file.

use std::collections::BTreeSet;
use std::fmt::Write as _;
use std::fs;
use std::path::Path;

use anyhow::{Context, Result, bail};
use serde_json::json;

use crate::config::{AndroidApp, Config, IosApp, LinkPath, Links};
use crate::locale::{self, Localized};
use crate::resolve::App;
use crate::scan::Seg;
use crate::{analyze, diag};

/// Where each file goes, below the `out` folder. A file that isn't written for this config
/// (no `ios_app_id`, say) is removed by `fsp links` and reported stale by `--check`.
const ANDROID_FILTERS: &str = "android/intent-filters.xml";
const ASSET_LINKS: &str = "web/.well-known/assetlinks.json";
const IOS_ENTITLEMENTS: &str = "ios/associated-domains.entitlements";
const IOS_URL_TYPES: &str = "ios/info-url-types.xml";
const AASA: &str = "web/.well-known/apple-app-site-association";
const SITEMAP: &str = "web/sitemap.xml";

/// One piece of a URL path, with a locale's spelling chosen.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Piece {
    /// A static segment, as written (`products`, `führer`).
    Lit(String),
    /// A `$dynamic` segment: one segment of any value.
    Any,
    /// A `$$catch_all` (one or more segments) or `$$$catch_all` (`optional`: zero or more): the
    /// rest of the path. Always the last piece.
    Rest { optional: bool },
}

/// A route the app can be opened at.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Link {
    /// The canonical path first, then the others, each once.
    pub spellings: Vec<Vec<Piece>>,
    /// `(locale tag, its path)`, for the `hreflang` alternates.
    pub locales: Vec<(String, Vec<Piece>)>,
    /// Whether the route matches by case (`caseSensitive`).
    pub case_sensitive: bool,
    /// A `redirect.dart`: the app opens it, but a sitemap doesn't list a URL that redirects.
    pub redirect: bool,
    /// The route's canonical pattern, as the diagnostics write it (`/orders/:id`).
    pub pattern: String,
}

/// The path of `url` with the spellings of `locale` (the canonical ones for `None`): one piece
/// per segment, `(group)` folders adding none.
pub fn pieces(url: &[Seg], localized: &[Localized], locale: Option<&str>) -> Vec<Piece> {
    url.iter()
        .enumerate()
        .filter_map(|(i, s)| match s {
            Seg::Static(s) => Some(Piece::Lit(match (locale::at(localized, i), locale) {
                (Some(l), Some(tag)) => l.spelled(tag).to_string(),
                _ => s.clone(),
            })),
            Seg::Dynamic(_) => Some(Piece::Any),
            Seg::CatchAll(_, optional) => Some(Piece::Rest {
                optional: *optional,
            }),
            Seg::Group(_) => None,
        })
        .collect()
}

/// Every route that is `linkable`, in the order of the route table.
pub fn collect(app: &App) -> Vec<Link> {
    app.routes
        .iter()
        .filter(|r| r.is_route() && r.linkable)
        .map(|r| {
            let canonical = pieces(&r.url, &r.localized, None);
            let locales: Vec<(String, Vec<Piece>)> = locale::locales(&r.localized)
                .into_iter()
                .map(|tag| {
                    let p = pieces(&r.url, &r.localized, Some(&tag));
                    (tag, p)
                })
                .collect();
            let mut spellings = vec![canonical];
            for (_, p) in &locales {
                if !spellings.contains(p) {
                    spellings.push(p.clone());
                }
            }
            Link {
                spellings,
                locales,
                case_sensitive: r.case_sensitive,
                redirect: r.page.is_none(),
                pattern: crate::resolve::pattern(&r.url),
            }
        })
        .collect()
}

// --- Android ----------------------------------------------------------------

/// How an Android `<data>` element matches a path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AndroidPath {
    /// `android:path`: this path exactly.
    Exact(String),
    /// `android:pathPrefix`: paths that start with this.
    Prefix(String),
    /// `android:pathPattern`: `.*` is anything, `.` any one character, `\\` escapes.
    Pattern(String),
}

impl AndroidPath {
    fn attr(&self) -> (&'static str, &str) {
        match self {
            AndroidPath::Exact(p) => ("path", p),
            AndroidPath::Prefix(p) => ("pathPrefix", p),
            AndroidPath::Pattern(p) => ("pathPattern", p),
        }
    }
}

/// A literal segment in an Android `pathPattern`: `.` and `*` are special in it, and `\` is
/// the escape. The pattern is read from XML first, so each escape is written twice.
fn android_literal(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars() {
        if matches!(c, '.' | '*' | '\\') {
            out.push_str("\\\\");
        }
        out.push(c);
    }
    out
}

/// The `<data>` paths that make Android open a route's path.
///
/// `pathPattern` can't say "one segment", so a `$dynamic` segment is `..*` (one character, then
/// anything) and also lets a longer path through: the app's router has the last word.
pub fn android_paths(path: &[Piece]) -> Vec<AndroidPath> {
    let (head, rest) = match path.split_last() {
        Some((Piece::Rest { optional }, head)) => (head, Some(*optional)),
        _ => (path, None),
    };
    let literal = head.iter().all(|p| matches!(p, Piece::Lit(_)));
    if literal {
        let base: String = head
            .iter()
            .map(|p| match p {
                Piece::Lit(s) => format!("/{s}"),
                _ => String::new(),
            })
            .collect();
        let exact = if base.is_empty() {
            "/".to_string()
        } else {
            base.clone()
        };
        let prefix = format!("{base}/");
        return match rest {
            None => vec![AndroidPath::Exact(exact)],
            Some(false) => vec![AndroidPath::Prefix(prefix)],
            Some(true) => vec![AndroidPath::Exact(exact), AndroidPath::Prefix(prefix)],
        };
    }
    let base: String = head
        .iter()
        .map(|p| match p {
            Piece::Lit(s) => format!("/{}", android_literal(s)),
            _ => "/..*".to_string(),
        })
        .collect();
    match rest {
        None => vec![AndroidPath::Pattern(base)],
        Some(false) => vec![AndroidPath::Pattern(format!("{base}/..*"))],
        Some(true) => vec![
            AndroidPath::Pattern(base.clone()),
            AndroidPath::Pattern(format!("{base}/..*")),
        ],
    }
}

/// The text of an XML attribute value.
fn xml_attr(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            c => out.push(c),
        }
    }
    out
}

/// An Android `<data>` path of a `paths:` entry: `/x` is `path`, `/x/*` is `pathPrefix="/x/"`.
fn android_listed(path: &LinkPath) -> AndroidPath {
    let join = |segs: &[String]| segs.iter().map(|s| format!("/{s}")).collect::<String>();
    match path {
        LinkPath::Exact(segs) if segs.is_empty() => AndroidPath::Exact("/".into()),
        LinkPath::Exact(segs) => AndroidPath::Exact(join(segs)),
        LinkPath::Prefix(segs) => AndroidPath::Prefix(format!("{}/", join(segs))),
    }
}

/// The paths of all links as `<data>` paths, each once, in route order; `paths:` replaces them.
fn android_data(links: &[Link], cfg: &Links) -> Vec<AndroidPath> {
    if let Some(paths) = &cfg.paths {
        return paths.iter().map(android_listed).collect();
    }
    let mut seen = BTreeSet::new();
    let mut out = vec![];
    for path in links.iter().flat_map(|l| &l.spellings) {
        for p in android_paths(path) {
            if seen.insert(format!("{p:?}")) {
                out.push(p);
            }
        }
    }
    out
}

fn android_filters(links: &[Link], cfg: &Links) -> String {
    let data = android_data(links, cfg);
    let mut out = String::new();
    out.push_str(
        "<!-- Written by `fsp links` from lib/app: don't edit it, run `fsp links` again.\n\
         \x20    Paste these elements into the <activity> of android/app/src/main/AndroidManifest.xml\n\
         \x20    that has the MAIN/LAUNCHER intent filter, replacing the ones pasted before. -->\n",
    );
    let filter = |out: &mut String,
                  verify: bool,
                  schemes: &[&str],
                  hosts: &[String],
                  paths: &[AndroidPath]| {
        if verify {
            out.push_str("<intent-filter android:autoVerify=\"true\">\n");
        } else {
            out.push_str("<intent-filter>\n");
        }
        out.push_str("    <action android:name=\"android.intent.action.VIEW\" />\n");
        out.push_str("    <category android:name=\"android.intent.category.DEFAULT\" />\n");
        out.push_str("    <category android:name=\"android.intent.category.BROWSABLE\" />\n");
        for s in schemes {
            let _ = writeln!(out, "    <data android:scheme=\"{}\" />", xml_attr(s));
        }
        for h in hosts {
            let _ = writeln!(out, "    <data android:host=\"{}\" />", xml_attr(h));
        }
        for p in paths {
            let (attr, value) = p.attr();
            let _ = writeln!(out, "    <data android:{attr}=\"{}\" />", xml_attr(value));
        }
        out.push_str("</intent-filter>\n");
    };
    for domain in &cfg.domains {
        filter(
            &mut out,
            true,
            &["https"],
            std::slice::from_ref(domain),
            &data,
        );
    }
    if let Some(scheme) = &cfg.scheme {
        if cfg.scheme_host {
            filter(&mut out, false, &[scheme.as_str()], &cfg.domains, &data);
        } else {
            // No host, so no path: Android ignores the path attributes of a filter without one.
            filter(&mut out, false, &[scheme.as_str()], &[], &[]);
        }
    }
    out
}

fn asset_links(apps: &[AndroidApp]) -> String {
    let doc: Vec<_> = apps
        .iter()
        .map(|a| {
            json!({
                "relation": ["delegate_permission/common.handle_all_urls"],
                "target": {
                    "namespace": "android_app",
                    "package_name": a.package,
                    "sha256_cert_fingerprints": a.sha256,
                },
            })
        })
        .collect();
    json_text(&json!(doc))
}

fn json_text(v: &serde_json::Value) -> String {
    // A `Value` always serializes.
    let mut s = serde_json::to_string_pretty(v).unwrap_or_default();
    s.push('\n');
    s
}

// --- iOS --------------------------------------------------------------------

/// A path segment as a URL writes it: everything beyond the unreserved characters as `%XX`
/// (upper-case hex of the UTF-8 bytes), so nothing in it is special to a matcher.
pub fn url_segment(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~') {
            out.push(char::from(b));
        } else {
            let _ = write!(out, "%{b:02X}");
        }
    }
    out
}

/// The `components` paths (`"/"` keys of the association file) that make iOS open a route's
/// path: `?` is exactly one character and `*` any run of them, so a `$dynamic` segment is `?*`.
pub fn aasa_paths(path: &[Piece]) -> Vec<String> {
    let (head, rest) = match path.split_last() {
        Some((Piece::Rest { optional }, head)) => (head, Some(*optional)),
        _ => (path, None),
    };
    let base: String = head
        .iter()
        .map(|p| match p {
            Piece::Lit(s) => format!("/{}", url_segment(s)),
            _ => "/?*".to_string(),
        })
        .collect();
    let exact = if base.is_empty() {
        "/".to_string()
    } else {
        base.clone()
    };
    match rest {
        None => vec![exact],
        Some(false) => vec![format!("{base}/?*")],
        Some(true) => vec![exact, format!("{base}/*")],
    }
}

/// The `components` path of a `paths:` entry: `/x`, or `/x/*` for everything below it.
fn aasa_listed(path: &LinkPath) -> String {
    let join = |segs: &[String]| -> String {
        segs.iter()
            .map(|s| format!("/{}", url_segment(s)))
            .collect()
    };
    match path {
        LinkPath::Exact(segs) if segs.is_empty() => "/".to_string(),
        LinkPath::Exact(segs) => join(segs),
        LinkPath::Prefix(segs) => format!("{}/*", join(segs)),
    }
}

fn aasa(links: &[Link], cfg: &Links, apps: &[IosApp]) -> String {
    let mut seen = BTreeSet::new();
    let mut components = vec![];
    if let Some(paths) = &cfg.paths {
        for p in paths {
            components.push(json!({"/": aasa_listed(p)}));
        }
    }
    for l in links.iter().filter(|_| cfg.paths.is_none()) {
        for path in &l.spellings {
            for p in aasa_paths(path) {
                if seen.insert((p.clone(), l.case_sensitive)) {
                    components.push(if l.case_sensitive {
                        json!({"/": p})
                    } else {
                        json!({"/": p, "caseSensitive": false})
                    });
                }
            }
        }
    }
    let ids: Vec<&str> = apps.iter().map(|a| a.app_id.as_str()).collect();
    json_text(&json!({
        "applinks": {
            "details": [{"appIDs": ids, "components": components}],
        },
    }))
}

const PLIST_HEAD: &str = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n";

fn entitlements(domains: &[String]) -> String {
    let mut out = String::from(PLIST_HEAD);
    out.push_str(
        "<!-- Written by `fsp links`: add these entries to ios/Runner/Runner.entitlements. -->\n",
    );
    out.push_str("<plist version=\"1.0\">\n<dict>\n");
    out.push_str("\t<key>com.apple.developer.associated-domains</key>\n\t<array>\n");
    for d in domains {
        let _ = writeln!(out, "\t\t<string>applinks:{}</string>", xml_attr(d));
    }
    out.push_str("\t</array>\n</dict>\n</plist>\n");
    out
}

fn url_types(scheme: &str, app_id: &str) -> String {
    // The bundle id is what follows the Team ID.
    let bundle = app_id.split_once('.').map_or(app_id, |(_, b)| b);
    format!(
        "<!-- Written by `fsp links`: add this to the top-level <dict> of ios/Runner/Info.plist. -->\n\
<key>CFBundleURLTypes</key>\n\
<array>\n\
\t<dict>\n\
\t\t<key>CFBundleURLName</key>\n\
\t\t<string>{}</string>\n\
\t\t<key>CFBundleURLSchemes</key>\n\
\t\t<array>\n\
\t\t\t<string>{}</string>\n\
\t\t</array>\n\
\t</dict>\n\
</array>\n",
        xml_attr(bundle),
        xml_attr(scheme)
    )
}

// --- Web --------------------------------------------------------------------

/// A static path (no `$dynamic` or catch-all segment) as a URL path; `None` for any other.
fn static_path(path: &[Piece]) -> Option<String> {
    let mut out = String::new();
    for p in path {
        match p {
            Piece::Lit(s) => {
                out.push('/');
                out.push_str(&url_segment(s));
            }
            _ => return None,
        }
    }
    Some(if out.is_empty() { "/".into() } else { out })
}

/// `sitemap.xml`: each static route once per spelling, as an absolute URL on `domain`, with
/// the `hreflang` alternates of a localized one. Redirects aren't listed.
fn sitemap(links: &[Link], domain: &str) -> String {
    let url = |p: &[Piece]| static_path(p).map(|p| format!("https://{domain}{p}"));
    let mut out = String::from(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\" xmlns:xhtml=\"http://www.w3.org/1999/xhtml\">\n",
    );
    let mut seen = BTreeSet::new();
    for l in links.iter().filter(|l| !l.redirect) {
        let Some(canonical) = url(&l.spellings[0]) else {
            continue;
        };
        let mut alternates = vec![];
        if !l.locales.is_empty() {
            alternates.push(("x-default".to_string(), canonical.clone()));
            for (tag, p) in &l.locales {
                alternates.extend(url(p).map(|u| (tag.replace('_', "-"), u)));
            }
        }
        for spelling in &l.spellings {
            let Some(loc) = url(spelling) else { continue };
            if !seen.insert(loc.clone()) {
                continue;
            }
            out.push_str("  <url>\n");
            let _ = writeln!(out, "    <loc>{}</loc>", xml_attr(&loc));
            for (lang, href) in &alternates {
                let _ = writeln!(
                    out,
                    "    <xhtml:link rel=\"alternate\" hreflang=\"{}\" href=\"{}\" />",
                    xml_attr(lang),
                    xml_attr(href)
                );
            }
            out.push_str("  </url>\n");
        }
    }
    out.push_str("</urlset>\n");
    out
}

// --- `paths:` against the routes ----------------------------------------------

/// Whether a path piece can be the `seg` a `paths:` entry spells: a `$dynamic` segment takes
/// any one.
fn piece_fits(piece: &Piece, seg: &str) -> bool {
    match piece {
        Piece::Lit(s) => s == seg,
        Piece::Any | Piece::Rest { .. } => true,
    }
}

/// Whether some URL is both in the `paths:` entry and a path of the route.
fn entry_meets(entry: &LinkPath, route: &[Piece]) -> bool {
    let (segs, prefix) = match entry {
        LinkPath::Exact(segs) => (segs, false),
        LinkPath::Prefix(segs) => (segs, true),
    };
    let (head, rest) = match route.split_last() {
        Some((Piece::Rest { optional }, head)) => (head, Some(*optional)),
        _ => (route, None),
    };
    let common = head.len().min(segs.len());
    if !head[..common]
        .iter()
        .zip(segs)
        .all(|(p, s)| piece_fits(p, s))
    {
        return false;
    }
    match (head.len().cmp(&segs.len()), prefix, rest) {
        // The route is longer than the entry's segments: only a prefix reaches that far.
        (std::cmp::Ordering::Greater, p, _) => p,
        (std::cmp::Ordering::Equal, false, Some(false)) => false,
        (std::cmp::Ordering::Equal, false, _) => true,
        // A prefix needs at least one more segment, which the route has when it ends in a rest.
        (std::cmp::Ordering::Equal, true, r) => r.is_some(),
        // The entry is longer: the route's rest segments can take the difference.
        (std::cmp::Ordering::Less, _, r) => r.is_some(),
    }
}

/// Whether the entry opens every URL of the route, so the route needs no other entry.
fn entry_covers(entry: &LinkPath, route: &[Piece]) -> bool {
    match entry {
        LinkPath::Exact(segs) => {
            segs.len() == route.len()
                && route
                    .iter()
                    .zip(segs)
                    .all(|(p, s)| matches!(p, Piece::Lit(l) if l == s))
        }
        LinkPath::Prefix(segs) => {
            route.len() > segs.len()
                && route
                    .iter()
                    .zip(segs)
                    .all(|(p, s)| matches!(p, Piece::Lit(l) if l == s))
        }
    }
}

/// What `paths:` and the routes disagree about, as warnings (`fsp links` prints them; `--check`
/// does not fail on them): a linkable route no entry covers, and an entry no route matches.
pub fn warnings(app: &App, cfg: &Links) -> Vec<String> {
    let Some(paths) = &cfg.paths else {
        return vec![];
    };
    let links = collect(app);
    let mut out = vec![];
    for l in &links {
        let covered = l
            .spellings
            .iter()
            .all(|sp| paths.iter().any(|p| entry_covers(p, sp)));
        if covered {
            continue;
        }
        let prefix: String = l.spellings[0]
            .iter()
            .map_while(|p| match p {
                Piece::Lit(s) => Some(format!("/{s}")),
                _ => None,
            })
            .collect();
        out.push(format!(
            "`{}` is linkable, and no `fespalier.links.paths` entry covers it: add `{prefix}/*`, or `const linkable = false;` in its route.dart",
            l.pattern
        ));
    }
    for p in paths {
        let hit = links
            .iter()
            .any(|l| l.spellings.iter().any(|sp| entry_meets(p, sp)));
        if !hit {
            let text = match p {
                LinkPath::Exact(segs) if segs.is_empty() => "/".to_string(),
                LinkPath::Exact(segs) => segs.iter().map(|s| format!("/{s}")).collect(),
                LinkPath::Prefix(segs) => {
                    format!(
                        "{}/*",
                        segs.iter().map(|s| format!("/{s}")).collect::<String>()
                    )
                }
            };
            out.push(format!(
                "`fespalier.links.paths`: `{text}` matches no linkable route"
            ));
        }
    }
    out
}

// --- The files --------------------------------------------------------------

/// One file of the output: its path below `out`, and its text, or `None` when this config
/// writes none (a file left from before is stale).
#[derive(Debug, PartialEq, Eq)]
pub struct OutFile {
    pub path: &'static str,
    pub text: Option<String>,
}

/// All the files for `app` as `cfg` asks, in a fixed order.
pub fn files(app: &App, cfg: &Links) -> Result<Vec<OutFile>> {
    let links = collect(app);
    if links.is_empty() {
        bail!(
            "no route can be linked: the app has no page, or every folder says `const linkable = false;`"
        );
    }
    let android = (!cfg.apps_android.is_empty()).then_some(&cfg.apps_android);
    // The bundle id of the first iOS app names the URL type, as every flavour shares the scheme.
    let ios = cfg.apps_ios.first();
    let file = |path, text: Option<String>| OutFile { path, text };
    Ok(vec![
        file(
            ANDROID_FILTERS,
            android.map(|_| android_filters(&links, cfg)),
        ),
        file(ASSET_LINKS, android.map(|a| asset_links(a))),
        file(IOS_ENTITLEMENTS, ios.map(|_| entitlements(&cfg.domains))),
        file(
            IOS_URL_TYPES,
            ios.zip(cfg.scheme.as_deref())
                .map(|(app, scheme)| url_types(scheme, &app.app_id)),
        ),
        file(AASA, ios.map(|_| aasa(&links, cfg, &cfg.apps_ios))),
        file(SITEMAP, Some(sitemap(&links, &cfg.domains[0]))),
    ])
}

/// `fsp links` (write) and `fsp links --check` (compare, change nothing, fail when stale).
pub fn run(project: &Path, check: bool) -> Result<()> {
    let cfg = Config::load(project)?;
    let Some(raw) = &cfg.links else {
        bail!(
            "no `links:` in the `fespalier:` section of pubspec.yaml; add the domains the app opens, e.g.\n  fespalier:\n    links:\n      domains: [shop.example.com]"
        );
    };
    let links = raw.validate()?;
    let app_dir = project.join(&cfg.app_dir);
    if !app_dir.is_dir() {
        bail!(
            "{} not found (set `fespalier: app_dir:` in pubspec.yaml, or run `fsp init`)",
            app_dir.display()
        );
    }
    let (_, diags, app) = analyze(&app_dir, &cfg)?;
    diag::render(&app_dir, &cfg.app_dir, &diags);
    if diags.has_errors() {
        bail!("{} error(s); no links", diags.error_count());
    }
    let out = &links.out;
    let shown = |f: &OutFile| {
        if out.is_empty() {
            f.path.to_string()
        } else {
            format!("{out}/{}", f.path)
        }
    };
    let outputs = files(&app, &links)?;
    for w in warnings(&app, &links) {
        eprintln!("warning: {w}");
    }
    let count = outputs.iter().filter(|f| f.text.is_some()).count();
    let folder = if out.is_empty() { "." } else { out.as_str() };
    let (mut written, mut stale) = (0, vec![]);
    for f in &outputs {
        let path = project.join(shown(f));
        let on_disk = fs::read(&path).ok();
        match (&f.text, &on_disk) {
            (Some(text), Some(disk)) if text.as_bytes() == disk.as_slice() => continue,
            (Some(_), None) => stale.push(format!("{} is missing", shown(f))),
            (Some(_), Some(_)) => stale.push(format!("{} is out of date", shown(f))),
            (None, Some(_)) => stale.push(format!("{} is not wanted by this config", shown(f))),
            (None, None) => continue,
        }
        if check {
            continue;
        }
        if let Some(text) = &f.text {
            if let Some(dir) = path.parent() {
                fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
            }
            fs::write(&path, text).with_context(|| format!("writing {}", path.display()))?;
            eprintln!("  wrote {}", shown(f));
            written += 1;
        } else {
            fs::remove_file(&path).with_context(|| format!("removing {}", path.display()))?;
            eprintln!("  removed {}", shown(f));
        }
    }
    if check {
        if stale.is_empty() {
            eprintln!("✓ links: {count} files in {folder} are up to date");
            return Ok(());
        }
        for s in &stale {
            eprintln!("{s}");
        }
        bail!("{} file(s) out of date; run `fsp links`", stale.len());
    }
    eprintln!(
        "✓ links: {count} files in {folder} ({written} written, {} unchanged)",
        count - written
    );
    Ok(())
}
