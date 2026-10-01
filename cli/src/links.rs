//! `fsp links`: App Links, Universal Links and a sitemap, written from the route tree.
//!
//! The URLs the app opens are the routes' paths, so the lists the platforms want are derived
//! from them instead of kept by hand:
//!
//! - **Android**: `<intent-filter android:autoVerify="true">` elements (one per domain, and one
//!   for a custom scheme) to paste into the main activity of `AndroidManifest.xml`, which `fsp`
//!   never edits, and `assetlinks.json`.
//! - **iOS**: `apple-app-site-association` (`components`), the `applinks:` entitlement entries
//!   and, for a custom scheme, the `CFBundleURLTypes` entry.
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

use crate::config::{Config, Links};
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

/// The paths of all links as `<data>` paths, each once, in route order.
fn android_data(links: &[Link]) -> Vec<AndroidPath> {
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
    let data = android_data(links);
    let mut out = String::new();
    out.push_str(
        "<!-- Written by `fsp links` from lib/app: don't edit it, run `fsp links` again.\n\
         \x20    Paste these elements into the <activity> of android/app/src/main/AndroidManifest.xml\n\
         \x20    that has the MAIN/LAUNCHER intent filter, replacing the ones pasted before. -->\n",
    );
    let filter = |out: &mut String, verify: bool, schemes: &[&str], hosts: &[String]| {
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
        for p in &data {
            let (attr, value) = p.attr();
            let _ = writeln!(out, "    <data android:{attr}=\"{}\" />", xml_attr(value));
        }
        out.push_str("</intent-filter>\n");
    };
    for domain in &cfg.domains {
        filter(&mut out, true, &["https"], std::slice::from_ref(domain));
    }
    if let Some(scheme) = &cfg.scheme {
        filter(&mut out, false, &[scheme.as_str()], &cfg.domains);
    }
    out
}

fn asset_links(package: &str, fingerprints: &[String]) -> String {
    let doc = json!([{
        "relation": ["delegate_permission/common.handle_all_urls"],
        "target": {
            "namespace": "android_app",
            "package_name": package,
            "sha256_cert_fingerprints": fingerprints,
        },
    }]);
    json_text(&doc)
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

fn aasa(links: &[Link], app_id: &str) -> String {
    let mut seen = BTreeSet::new();
    let mut components = vec![];
    for l in links {
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
    json_text(&json!({
        "applinks": {
            "details": [{"appIDs": [app_id], "components": components}],
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
    let android = cfg.android.as_ref();
    let ios = cfg.ios_app_id.as_deref();
    let file = |path, text: Option<String>| OutFile { path, text };
    Ok(vec![
        file(
            ANDROID_FILTERS,
            android.map(|_| android_filters(&links, cfg)),
        ),
        file(
            ASSET_LINKS,
            android.map(|a| asset_links(&a.package, &a.sha256)),
        ),
        file(IOS_ENTITLEMENTS, ios.map(|_| entitlements(&cfg.domains))),
        file(
            IOS_URL_TYPES,
            ios.zip(cfg.scheme.as_deref())
                .map(|(id, scheme)| url_types(scheme, id)),
        ),
        file(AASA, ios.map(|id| aasa(&links, id))),
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
