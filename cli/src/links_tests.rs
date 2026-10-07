//! `fsp links`: the paths each platform gets from a route, the `linkable` flag, the config
//! errors, golden files for `examples/features`, and that `--check` sees what is stale.
//!
//! The goldens are in `tests/golden/links-features/`; `FSP_UPDATE_GOLDEN=1 cargo test links_tests::`
//! rewrites them.

use std::fs;
use std::path::{Path, PathBuf};

use crate::config::{Config, Links, Pubspec};
use crate::links::{self, AndroidPath, Piece};
use crate::scan::Seg;

use AndroidPath::{Exact, Pattern, Prefix};

const FINGERPRINT: &str = "14:6D:E9:83:C5:73:06:50:D8:EE:B9:95:2F:34:FC:64:16:A0:83:42:E6:1D:BE:A8:8A:04:96:B2:3F:CF:44:E5";

fn lit(s: &str) -> Piece {
    Piece::Lit(s.to_string())
}

fn examples(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../examples")
        .join(name)
}

/// A `links:` section from `lines`, validated.
fn links_cfg(lines: &[&str]) -> anyhow::Result<Links> {
    let body: String = lines.iter().map(|l| format!("    {l}\n")).collect();
    let yaml = format!("name: demo\nfespalier:\n  links:\n{body}");
    Pubspec::parse(&yaml)?
        .config
        .links
        .expect("a links section")
        .validate()
}

fn error_of(lines: &[&str]) -> String {
    format!("{:#}", links_cfg(lines).unwrap_err())
}

fn full() -> Links {
    links_cfg(&[
        "domains: [shop.example.com, www.shop.example.com]",
        "scheme: myshop",
        "android_package: com.example.shop",
        &format!("android_sha256: [\"{FINGERPRINT}\"]"),
        "ios_app_id: ABCDE12345.com.example.shop",
    ])
    .unwrap()
}

fn app_of(project: &Path) -> crate::resolve::App {
    let cfg = Config::load(project).unwrap();
    let (_, diags, app) = crate::analyze(&project.join(&cfg.app_dir), &cfg).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    app
}

fn project(files: &[(&str, &str)]) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("pubspec.yaml"), "name: demo\n").unwrap();
    for (rel, body) in files {
        let p = dir.path().join("lib/app").join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, body).unwrap();
    }
    dir
}

fn page(name: &str) -> String {
    format!("class {name}Page extends StatelessWidget {{ const {name}Page({{super.key}}); }}")
}

fn dynamic_page(name: &str, param: &str) -> String {
    format!(
        "class {name}Page extends StatelessWidget {{ const {name}Page({{super.key, required this.{param}}}); final String {param}; }}"
    )
}

// --- the paths of a route ------------------------------------------------------

#[test]
fn a_static_path_is_exact_on_android_and_ios() {
    assert_eq!(links::android_paths(&[]), [Exact("/".into())]);
    assert_eq!(
        links::android_paths(&[lit("about"), lit("team")]),
        [Exact("/about/team".into())]
    );
    assert_eq!(links::aasa_paths(&[]), ["/"]);
    assert_eq!(
        links::aasa_paths(&[lit("about"), lit("team")]),
        ["/about/team"]
    );
}

#[test]
fn a_dynamic_segment_is_a_wildcard_that_cannot_be_empty() {
    let path = [lit("products"), Piece::Any];
    assert_eq!(
        links::android_paths(&path),
        [Pattern("/products/..*".into())]
    );
    assert_eq!(links::aasa_paths(&path), ["/products/?*"]);
    let path = [lit("shops"), Piece::Any, lit("items"), Piece::Any];
    assert_eq!(
        links::android_paths(&path),
        [Pattern("/shops/..*/items/..*".into())]
    );
    assert_eq!(links::aasa_paths(&path), ["/shops/?*/items/?*"]);
    assert_eq!(
        links::android_paths(&[Piece::Any]),
        [Pattern("/..*".into())]
    );
}

#[test]
fn a_catch_all_is_a_prefix() {
    let required = [lit("docs"), Piece::Rest { optional: false }];
    assert_eq!(links::android_paths(&required), [Prefix("/docs/".into())]);
    assert_eq!(links::aasa_paths(&required), ["/docs/?*"]);
    // `$$$path` also answers the bare folder.
    let optional = [lit("files"), Piece::Rest { optional: true }];
    assert_eq!(
        links::android_paths(&optional),
        [Exact("/files".into()), Prefix("/files/".into())]
    );
    assert_eq!(links::aasa_paths(&optional), ["/files", "/files/*"]);
    // After a dynamic segment, a prefix is a pattern.
    let nested = [
        lit("orders"),
        Piece::Any,
        lit("files"),
        Piece::Rest { optional: false },
    ];
    assert_eq!(
        links::android_paths(&nested),
        [Pattern("/orders/..*/files/..*".into())]
    );
    assert_eq!(links::aasa_paths(&nested), ["/orders/?*/files/?*"]);
}

#[test]
fn what_a_matcher_reads_as_syntax_is_escaped() {
    // `pathPattern` is read as XML and then as a pattern: `.` and `*` are written `\\.`, `\\*`.
    assert_eq!(
        links::android_paths(&[lit("v1.0"), Piece::Any]),
        [Pattern("/v1\\\\.0/..*".into())]
    );
    // An exact `path` is compared as it is.
    assert_eq!(
        links::android_paths(&[lit("v1.0")]),
        [Exact("/v1.0".into())]
    );
    // The association file takes the encoded path, and encodes what is special to it.
    assert_eq!(links::aasa_paths(&[lit("führer")]), ["/f%C3%BChrer"]);
    assert_eq!(links::aasa_paths(&[lit("a*b?c")]), ["/a%2Ab%3Fc"]);
    assert_eq!(links::url_segment("a b%"), "a%20b%25");
    assert_eq!(links::url_segment("a-b_c.d~e"), "a-b_c.d~e");
}

#[test]
fn a_locale_spells_its_own_segments() {
    let dir = project(&[
        ("help/page.dart", &page("Help")),
        (
            "help/route.dart",
            "const paths = {'fr': 'aide', 'de': 'hilfe'};",
        ),
        ("help/$topic/page.dart", &dynamic_page("HelpTopic", "topic")),
        ("help/contact/page.dart", &page("Contact")),
        (
            "help/contact/route.dart",
            "const paths = {'de': 'kontakt'};",
        ),
    ]);
    let app = app_of(dir.path());
    let all = links::collect(&app);
    let contact = all
        .iter()
        .find(|l| l.spellings[0] == [lit("help"), lit("contact")])
        .unwrap();
    assert_eq!(
        contact.spellings,
        [
            vec![lit("help"), lit("contact")],
            vec![lit("aide"), lit("contact")],
            vec![lit("hilfe"), lit("kontakt")],
        ]
    );
    assert_eq!(
        contact.locales,
        [
            ("fr".to_string(), vec![lit("aide"), lit("contact")]),
            ("de".to_string(), vec![lit("hilfe"), lit("kontakt")]),
        ]
    );
    let url = [Seg::Static("help".into()), Seg::Dynamic("topic".into())];
    assert_eq!(links::pieces(&url, &[], None), [lit("help"), Piece::Any]);
}

// --- `linkable` ----------------------------------------------------------------

fn spelled(files: &[(&str, &str)]) -> Vec<String> {
    let dir = project(files);
    links::collect(&app_of(dir.path()))
        .iter()
        .map(|l| links::aasa_paths(&l.spellings[0]).join(" "))
        .collect()
}

#[test]
fn linkable_false_leaves_a_folder_and_everything_below_it_out() {
    let all = spelled(&[
        ("page.dart", &page("Home")),
        ("admin/page.dart", &page("Admin")),
        ("admin/route.dart", "const linkable = false;"),
        ("admin/users/page.dart", &page("Users")),
        ("shop/page.dart", &page("Shop")),
    ]);
    assert_eq!(all, ["/", "/shop"]);
}

#[test]
fn the_nearest_linkable_wins_and_groups_and_pageless_folders_pass_it_on() {
    let all = spelled(&[
        ("page.dart", &page("Home")),
        ("route.dart", "const linkable = false;"),
        ("(shop)/route.dart", "const linkable = false;"),
        ("(shop)/cart/page.dart", &page("Cart")),
        ("(shop)/cart/route.dart", "const linkable = true;"),
        ("(shop)/cart/pay/page.dart", &page("Pay")),
        ("legal/terms/page.dart", &page("Terms")),
    ]);
    // The root says no to everything; the cart folder turns it on again, for `pay` too.
    assert_eq!(all, ["/cart", "/cart/pay"]);
}

#[test]
fn linkable_may_stand_alone_in_a_route_dart_and_sits_beside_the_others() {
    let all = spelled(&[
        ("page.dart", &page("Home")),
        (
            "help/route.dart",
            "const caseSensitive = false;\nconst linkable = false;\nconst paths = {'fr': 'aide'};",
        ),
        ("help/page.dart", &page("Help")),
    ]);
    assert_eq!(all, ["/"]);
}

fn errors(files: &[(&str, &str)]) -> Vec<String> {
    let dir = project(files);
    let cfg = Config::load(dir.path()).unwrap();
    let (_, diags, _) = crate::analyze(&dir.path().join("lib/app"), &cfg).unwrap();
    diags.0.iter().map(ToString::to_string).collect()
}

#[test]
fn linkable_must_be_a_literal_and_declared_once() {
    let home = ("page.dart", page("Home"));
    for body in [
        "const linkable = flag;",
        "const linkable = !true;",
        "const linkable = 'no';",
    ] {
        let e = errors(&[("route.dart", body), (home.0, &home.1)]);
        assert_eq!(
            e,
            [
                "✗ route.dart:1  `linkable` must be a `true` or `false` literal: fsp reads it from the source, it doesn't run it"
            ],
            "{body}"
        );
    }
    let e = errors(&[
        (
            "route.dart",
            "const linkable = false;\nconst linkable = true;",
        ),
        (home.0, &home.1),
    ]);
    assert_eq!(e, ["✗ route.dart:2  `linkable` is declared twice"]);
}

#[test]
fn a_route_dart_with_nothing_it_knows_names_all_seven() {
    let e = errors(&[
        ("route.dart", "const other = 1;"),
        ("page.dart", &page("Home")),
    ]);
    assert_eq!(
        e,
        [
            "✗ route.dart  expected `const caseSensitive = false;` (or `true`), `const paths = {'fr': 'produits'};`, `const nest = false;`, `const linkable = false;`, `const remount = Remount.onSegments;`, `const deferred = true;` or `const freshness = Freshness(staleTime: Duration(minutes: 5));`"
        ]
    );
}

// --- the config ----------------------------------------------------------------

#[test]
fn a_full_config_is_normalized() {
    let l = links_cfg(&[
        "domains: [Shop.Example.com, shop.example.com, '*.example.org']",
        "android_package: com.example.shop",
        &format!(
            "android_sha256: [\"{}\", \"{}\"]",
            FINGERPRINT.to_lowercase(),
            FINGERPRINT
        ),
        "ios_app_id: ABCDE12345.com.example.shop",
        "out: ./web//links/",
    ])
    .unwrap();
    assert_eq!(l.domains, ["shop.example.com", "*.example.org"]);
    let a = l.apps_android.into_iter().next().unwrap();
    assert_eq!(
        (a.package.as_str(), a.sha256),
        ("com.example.shop", vec![FINGERPRINT.to_string()])
    );
    assert_eq!(l.out, "web/links");
    assert_eq!(
        links_cfg(&["domains: [a.example.com]"]).unwrap().out,
        "links"
    );
    assert_eq!(
        links_cfg(&["domains: [a.example.com]", "out: ."])
            .unwrap()
            .out,
        ""
    );
}

#[test]
fn config_mistakes_name_the_key() {
    let d = "domains: [shop.example.com]";
    let e = error_of(&["scheme: myshop"]);
    assert!(
        e.starts_with("`fespalier.links.domains` is required"),
        "{e}"
    );
    assert!(error_of(&["domains: []"]).starts_with("`fespalier.links.domains` is required"));
    for bad in [
        "https://shop.example.com/",
        "shop.example.com:8080",
        "shop",
        "shop.example.com/x",
        "-a.example.com",
        "ü.example.com",
    ] {
        let e = error_of(&[&format!("domains: [{bad}]")]);
        assert!(
            e.starts_with(&format!(
                "`fespalier.links.domains`: `{}` is not a host name",
                bad.trim_matches('\'')
            )),
            "{bad}: {e}"
        );
    }
    let e = error_of(&["domains: ['*.example.com', shop.example.com]"]);
    assert!(e.contains("can't be the wildcard `*.example.com`"), "{e}");

    let e = error_of(&[d, "android_package: shop"]);
    assert!(
        e.starts_with("`fespalier.links.android_package` needs `android_sha256`"),
        "{e}"
    );
    let e = error_of(&[d, &format!("android_sha256: [\"{FINGERPRINT}\"]")]);
    assert!(
        e.starts_with("`fespalier.links.android_sha256` needs `android_package`"),
        "{e}"
    );
    for bad in [
        "shop",
        "com.1shop",
        "com.example.my-shop",
        "com..shop",
        "com.example.shop ",
    ] {
        let e = error_of(&[
            d,
            &format!("android_package: '{bad}'"),
            &format!("android_sha256: [\"{FINGERPRINT}\"]"),
        ]);
        assert!(
            e.starts_with("`fespalier.links.android_package` must be an Android application id like `com.example.shop`") && e.ends_with(&format!("got `{bad}`")),
            "{bad}: {e}"
        );
    }
    for bad in [
        "AB:CD",
        "14:6D:E9:83:C5:73:06:50:D8:EE:B9:95:2F:34:FC:64:16:A0:83:42:E6:1D:BE:A8:8A:04:96:B2:3F:CF:44",
        "ZZ:6D:E9:83:C5:73:06:50:D8:EE:B9:95:2F:34:FC:64:16:A0:83:42:E6:1D:BE:A8:8A:04:96:B2:3F:CF:44:E5",
    ] {
        let e = error_of(&[
            d,
            "android_package: com.example.shop",
            &format!("android_sha256: [\"{bad}\"]"),
        ]);
        assert!(
            e.starts_with(&format!(
                "`fespalier.links.android_sha256`: `{bad}` is not a SHA-256 fingerprint"
            )),
            "{e}"
        );
    }
    for bad in [
        "com.example.shop",
        "abcde12345.com.example.shop",
        "ABCDE1234.com.example.shop",
        "ABCDE12345.",
        "ABCDE12345.com..shop",
    ] {
        let e = error_of(&[d, &format!("ios_app_id: {bad}")]);
        assert!(
            e.starts_with(
                "`fespalier.links.ios_app_id` must be the Team ID, a dot and the bundle id"
            ),
            "{bad}: {e}"
        );
    }
    for bad in ["MyShop", "http", "https", "1shop", "my shop"] {
        let e = error_of(&[
            d,
            &format!("scheme: '{bad}'"),
            "ios_app_id: ABCDE12345.com.example.shop",
        ]);
        assert!(
            e.starts_with("`fespalier.links.scheme` must be a custom URL scheme in lower case"),
            "{bad}: {e}"
        );
    }
    let e = error_of(&[d, "scheme: myshop"]);
    assert!(
        e.starts_with("`fespalier.links.scheme` is written into the Android and iOS files"),
        "{e}"
    );
    for bad in ["/abs", "../x", "a/../../b", "C:\\x"] {
        let e = error_of(&[d, &format!("out: '{bad}'")]);
        assert!(
            e.starts_with("`fespalier.links.out` must be a folder inside the project"),
            "{bad}: {e}"
        );
    }
    let e = error_of(&[d, "out: ''"]);
    assert!(
        e.starts_with("`fespalier.links.out` must be a folder"),
        "{e}"
    );
}

#[test]
fn an_unknown_key_is_an_error_everywhere_and_a_bad_value_only_for_links() {
    let e = Pubspec::parse("name: demo\nfespalier:\n  links:\n    domain: [a.example.com]\n")
        .unwrap_err();
    assert!(format!("{e:#}").contains("unknown field `domain`"), "{e:#}");
    // `fsp gen` reads the section but never checks its values.
    let p =
        Pubspec::parse("name: demo\nfespalier:\n  links:\n    domains: ['not a host']\n").unwrap();
    assert!(p.config.links.is_some());
}

// --- the files -----------------------------------------------------------------

fn features() -> (Config, crate::resolve::App) {
    let cfg = Config::load(&examples("features")).unwrap();
    (cfg, app_of(&examples("features")))
}

fn written(links: &Links) -> Vec<(&'static str, String)> {
    let (_, app) = features();
    links::files(&app, links)
        .unwrap()
        .into_iter()
        .filter_map(|f| f.text.map(|t| (f.path, t)))
        .collect()
}

#[test]
fn goldens_of_examples_features() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/golden/links-features");
    let update = std::env::var_os("FSP_UPDATE_GOLDEN").is_some();
    let files = written(&full());
    assert_eq!(files.len(), 6);
    for (path, text) in &files {
        let golden = root.join(path);
        if update {
            fs::create_dir_all(golden.parent().unwrap()).unwrap();
            fs::write(&golden, text).unwrap();
        }
        let want = fs::read_to_string(&golden).unwrap_or_default();
        assert_eq!(
            *text,
            want,
            "{} is stale; run `FSP_UPDATE_GOLDEN=1 cargo test links_tests::` in cli/",
            golden.display()
        );
    }
}

#[test]
fn the_output_is_the_same_bytes_every_time() {
    assert_eq!(written(&full()), written(&full()));
}

#[test]
fn only_the_platforms_that_are_configured_are_written() {
    let only_ios = links_cfg(&[
        "domains: [shop.example.com]",
        "ios_app_id: ABCDE12345.com.example.shop",
    ])
    .unwrap();
    let names: Vec<_> = written(&only_ios).iter().map(|(p, _)| *p).collect();
    assert_eq!(
        names,
        [
            "ios/associated-domains.entitlements",
            "web/.well-known/apple-app-site-association",
            "web/sitemap.xml"
        ]
    );
    let nothing = links_cfg(&["domains: [shop.example.com]"]).unwrap();
    let names: Vec<_> = written(&nothing).iter().map(|(p, _)| *p).collect();
    assert_eq!(names, ["web/sitemap.xml"]);
}

#[test]
fn android_gets_a_filter_per_domain_and_one_for_the_scheme() {
    let files = written(&full());
    let xml = &files[0].1;
    assert_eq!(
        xml.matches("<intent-filter android:autoVerify=\"true\">")
            .count(),
        2
    );
    assert_eq!(xml.matches("<intent-filter>").count(), 1);
    assert!(xml.contains("<data android:scheme=\"myshop\" />"));
    assert!(xml.contains("<data android:host=\"www.shop.example.com\" />"));
    assert!(xml.contains("<data android:pathPattern=\"/catalog/..*/reviews\" />"));
    assert!(xml.contains("<data android:pathPrefix=\"/docs/\" />"));
    assert!(
        xml.contains("<data android:path=\"/aide\" />"),
        "localized spellings"
    );
    assert!(
        xml.contains("<data android:path=\"/führer\" />"),
        "raw: Android compares the decoded path"
    );
    assert!(!xml.contains("android:name=\"android.intent.action.MAIN\""));
}

#[test]
fn the_association_file_has_the_components_of_every_spelling() {
    let files = written(&full());
    let json: serde_json::Value = serde_json::from_str(&files[4].1).unwrap();
    let detail = &json["applinks"]["details"][0];
    assert_eq!(
        detail["appIDs"],
        serde_json::json!(["ABCDE12345.com.example.shop"])
    );
    let paths: Vec<&str> = detail["components"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["/"].as_str().unwrap())
        .collect();
    for want in [
        "/catalog/?*/reviews",
        "/docs/?*",
        "/files",
        "/files/*",
        "/hilfe/?*/beispiele",
        "/f%C3%BChrer",
    ] {
        assert!(paths.contains(&want), "{want} in {paths:?}");
    }
    // `features` is case-insensitive, and the association file says so.
    assert_eq!(detail["components"][0]["caseSensitive"], false);
    let mut unique = paths.clone();
    unique.sort_unstable();
    unique.dedup();
    assert_eq!(unique.len(), paths.len(), "each path once");
    let assets: serde_json::Value = serde_json::from_str(&files[1].1).unwrap();
    assert_eq!(assets[0]["target"]["package_name"], "com.example.shop");
    assert_eq!(
        assets[0]["target"]["sha256_cert_fingerprints"][0],
        FINGERPRINT
    );
}

#[test]
fn the_sitemap_lists_static_routes_with_their_alternates() {
    let files = written(&full());
    let xml = &files[5].1;
    assert!(xml.contains("<loc>https://shop.example.com/</loc>"));
    assert!(xml.contains("<loc>https://shop.example.com/docs/new</loc>"));
    assert!(xml.contains("<loc>https://shop.example.com/f%C3%BChrer</loc>"));
    assert!(xml.contains("hreflang=\"x-default\" href=\"https://shop.example.com/help\""));
    assert!(xml.contains("hreflang=\"fr\" href=\"https://shop.example.com/aide\""));
    // Dynamic routes, catch-alls and redirects aren't listed, and nothing is on the second domain.
    for out in [
        "/catalog/",
        "/docs/*",
        "/browse",
        "/old-search",
        "/orders",
        "www.shop",
        "/:",
    ] {
        assert!(!xml.contains(out), "{out}");
    }
    assert!(xml.starts_with("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<urlset "));
    assert!(xml.ends_with("</urlset>\n"));
}

#[test]
fn an_app_with_nothing_linkable_is_an_error() {
    let dir = project(&[
        ("page.dart", &page("Home")),
        ("route.dart", "const linkable = false;"),
    ]);
    let app = app_of(dir.path());
    let e = links::files(&app, &full()).unwrap_err();
    assert!(e.to_string().starts_with("no route can be linked"), "{e}");
}

// --- flavours, host-less schemes and path patterns (since 0.11.0) --------------------

const OTHER_FINGERPRINT: &str = "AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89";

fn flavored() -> Links {
    let sha = format!("android_sha256: [\"{FINGERPRINT}\"]");
    let other = format!("android_sha256: [\"{OTHER_FINGERPRINT}\"]");
    links_cfg(&[
        "domains: [shop.example.com]",
        "scheme: myshop",
        "flavors:",
        "  prod:",
        "    android_package: com.example.shop",
        &format!("    {sha}"),
        "    ios_app_id: ABCDE12345.com.example.shop",
        "  debug:",
        "    android_package: com.example.shop.debug",
        &format!("    {other}"),
        "    ios_app_id: ABCDE12345.com.example.shop.debug",
    ])
    .unwrap()
}

#[test]
fn flat_keys_and_one_flavour_give_the_same_files() {
    let flat = links_cfg(&[
        "domains: [shop.example.com]",
        "android_package: com.example.shop",
        &format!("android_sha256: [\"{FINGERPRINT}\"]"),
        "ios_app_id: ABCDE12345.com.example.shop",
    ])
    .unwrap();
    let one = links_cfg(&[
        "domains: [shop.example.com]",
        "flavors:",
        "  prod:",
        "    android_package: com.example.shop",
        &format!("    android_sha256: [\"{FINGERPRINT}\"]"),
        "    ios_app_id: ABCDE12345.com.example.shop",
    ])
    .unwrap();
    assert_eq!(written(&flat), written(&one));
    assert_eq!(flat.apps_android[0].flavor, None);
    assert_eq!(one.apps_android[0].flavor.as_deref(), Some("prod"));
}

#[test]
fn two_flavours_give_two_statements_and_two_app_ids() {
    let files = written(&flavored());
    let by = |name: &str| {
        files
            .iter()
            .find(|(p, _)| p.ends_with(name))
            .unwrap()
            .1
            .clone()
    };
    let assets: serde_json::Value = serde_json::from_str(&by("assetlinks.json")).unwrap();
    let packages: Vec<_> = assets
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["target"]["package_name"].as_str().unwrap())
        .collect();
    assert_eq!(packages, ["com.example.shop", "com.example.shop.debug"]);
    assert_eq!(
        assets[1]["target"]["sha256_cert_fingerprints"][0],
        OTHER_FINGERPRINT
    );
    let aasa: serde_json::Value = serde_json::from_str(&by("apple-app-site-association")).unwrap();
    assert_eq!(aasa["applinks"]["details"].as_array().unwrap().len(), 1);
    assert_eq!(
        aasa["applinks"]["details"][0]["appIDs"],
        serde_json::json!([
            "ABCDE12345.com.example.shop",
            "ABCDE12345.com.example.shop.debug"
        ])
    );
    // The bundle id of the first app names the URL type.
    assert!(by("info-url-types.xml").contains("<string>com.example.shop</string>"));
}

#[test]
fn a_hostless_scheme_filter_has_no_host_and_no_path() {
    let cfg = |host: &str| {
        links_cfg(&[
            "domains: [shop.example.com]",
            "scheme: myshop",
            host,
            "android_package: com.example.shop",
            &format!("android_sha256: [\"{FINGERPRINT}\"]"),
        ])
        .unwrap()
    };
    let files = written(&cfg("scheme_host: false"));
    let xml = &files[0].1;
    let filter = xml.split("<intent-filter>").nth(1).unwrap();
    let filter = filter.split("</intent-filter>").next().unwrap();
    assert_eq!(
        filter,
        "\n    <action android:name=\"android.intent.action.VIEW\" />\n    <category android:name=\"android.intent.category.DEFAULT\" />\n    <category android:name=\"android.intent.category.BROWSABLE\" />\n    <data android:scheme=\"myshop\" />\n"
    );
    // The https filter keeps its host and paths.
    assert!(xml.contains("<data android:host=\"shop.example.com\" />"));
    // `scheme_host: true` is the default, and what was written before.
    assert_eq!(
        written(&cfg("scheme_host: true")),
        written(&cfg("out: links"))
    );
    let with_host = &written(&cfg("scheme_host: true"))[0].1;
    let scheme_filter = with_host.split("<intent-filter>").nth(1).unwrap();
    assert!(scheme_filter.contains("<data android:host=\"shop.example.com\" />"));
}

#[test]
fn paths_replace_the_routes_on_android_and_in_the_association_file() {
    let l = links_cfg(&[
        "domains: [shop.example.com]",
        "android_package: com.example.shop",
        &format!("android_sha256: [\"{FINGERPRINT}\"]"),
        "ios_app_id: ABCDE12345.com.example.shop",
        "paths: [/, /about, /orders/*, /*, /führer]",
    ])
    .unwrap();
    let files = written(&l);
    let xml = &files[0].1;
    for want in [
        "<data android:path=\"/\" />",
        "<data android:path=\"/about\" />",
        "<data android:pathPrefix=\"/orders/\" />",
        "<data android:pathPrefix=\"/\" />",
        "<data android:path=\"/führer\" />",
    ] {
        assert!(xml.contains(want), "{want}");
    }
    assert!(!xml.contains("pathPattern"), "no route-derived entries");
    let aasa = files
        .iter()
        .find(|(p, _)| p.ends_with("association"))
        .unwrap();
    let json: serde_json::Value = serde_json::from_str(&aasa.1).unwrap();
    let got: Vec<&str> = json["applinks"]["details"][0]["components"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["/"].as_str().unwrap())
        .collect();
    assert_eq!(got, ["/", "/about", "/orders/*", "/*", "/f%C3%BChrer"]);
    // The sitemap still comes from the routes.
    let sitemap = files
        .iter()
        .find(|(p, _)| p.ends_with("sitemap.xml"))
        .unwrap();
    assert!(sitemap.1.contains("/docs/new"));
}

#[test]
fn paths_and_routes_that_disagree_are_warned_about() {
    let dir = project(&[
        ("page.dart", &page("Home")),
        ("about/page.dart", &page("About")),
        ("orders/$id/page.dart", &page("Order")),
        ("secret/page.dart", &page("Secret")),
    ]);
    let app = app_of(dir.path());
    let l = links_cfg(&[
        "domains: [shop.example.com]",
        "ios_app_id: ABCDE12345.com.example.shop",
        "paths: [/, /about, /orders/*, /nothing, /orders/42, /nothing/*]",
    ])
    .unwrap();
    assert_eq!(
        links::warnings(&app, &l),
        [
            "`/secret` is linkable, and no `fespalier.links.paths` entry covers it: add `/secret`, or `const linkable = false;` in its route.dart",
            "`fespalier.links.paths`: `/nothing` matches no linkable route",
            "`fespalier.links.paths`: `/nothing/*` matches no linkable route",
        ]
    );
    let none = links_cfg(&["domains: [shop.example.com]"]).unwrap();
    assert!(links::warnings(&app, &none).is_empty());
}

#[test]
fn the_advice_fits_the_shape_of_the_route() {
    let dir = project(&[
        ("page.dart", &page("Home")),
        ("orders/$id/page.dart", &dynamic_page("Order", "id")),
        ("docs/$$path/page.dart", &rest_page("Doc")),
        ("files/$$$path/page.dart", &rest_page("File")),
    ]);
    let app = app_of(dir.path());
    let l = links_cfg(&[
        "domains: [shop.example.com]",
        "ios_app_id: ABCDE12345.com.example.shop",
        "paths: [/nothing]",
    ])
    .unwrap();
    let w = links::warnings(&app, &l);
    for want in [
        "`/` is linkable, and no `fespalier.links.paths` entry covers it: add `/`, or",
        "`/orders/:id` is linkable, and no `fespalier.links.paths` entry covers it: add `/orders/*`, or",
        "add `/files` and `/files/*`, or",
    ] {
        assert!(w.iter().any(|m| m.contains(want)), "{want}: {w:?}");
    }
}

#[test]
fn a_root_prefix_covers_and_meets_every_route() {
    let dir = project(&[("page.dart", &page("Home"))]);
    let app = app_of(dir.path());
    let l = links_cfg(&[
        "domains: [shop.example.com]",
        "ios_app_id: ABCDE12345.com.example.shop",
        "paths: [/*]",
    ])
    .unwrap();
    assert!(links::warnings(&app, &l).is_empty());
    // `/files/*` does not open `/files`, which `$$$path` answers.
    let dir = project(&[("files/$$$path/page.dart", &rest_page("File"))]);
    let app = app_of(dir.path());
    let l = links_cfg(&[
        "domains: [shop.example.com]",
        "ios_app_id: ABCDE12345.com.example.shop",
        "paths: [/files/*]",
    ])
    .unwrap();
    let w = links::warnings(&app, &l);
    assert_eq!(w.len(), 1, "{w:?}");
    assert!(w[0].contains("add `/files` and `/files/*`"), "{w:?}");
}

#[test]
fn a_listed_path_keeps_a_case_insensitive_route_insensitive() {
    let dir = project(&[
        ("page.dart", &page("Home")),
        ("about/route.dart", "const caseSensitive = false;"),
        ("about/page.dart", &page("About")),
    ]);
    let app = app_of(dir.path());
    let l = links_cfg(&[
        "domains: [shop.example.com]",
        "ios_app_id: ABCDE12345.com.example.shop",
        "paths: [/, /about]",
    ])
    .unwrap();
    let files = links::files(&app, &l).unwrap();
    let aasa = files
        .iter()
        .find(|f| f.path.ends_with("association"))
        .and_then(|f| f.text.clone())
        .unwrap();
    let json: serde_json::Value = serde_json::from_str(&aasa).unwrap();
    let c = &json["applinks"]["details"][0]["components"];
    assert_eq!(c[0], serde_json::json!({"/": "/"}));
    assert_eq!(
        c[1],
        serde_json::json!({"/": "/about", "caseSensitive": false})
    );
}

#[test]
fn flavour_and_path_mistakes_name_the_key() {
    let d = "domains: [shop.example.com]";
    let sha = format!("android_sha256: [\"{FINGERPRINT}\"]");
    let flat_and_flavors = error_of(&[
        d,
        "ios_app_id: ABCDE12345.com.example.shop",
        "flavors:",
        "  prod:",
        "    ios_app_id: ABCDE12345.com.example.shop",
    ]);
    assert_eq!(
        flat_and_flavors,
        "`fespalier.links` takes `android_package`, `android_sha256` and `ios_app_id` for one app, or `flavors:` for several, not both"
    );
    for bad in ["Prod", "1x", "pro-d", "x y"] {
        assert_eq!(
            error_of(&[
                d,
                "flavors:",
                &format!("  '{bad}':"),
                "    ios_app_id: ABCDE12345.com.example.shop"
            ]),
            format!(
                "`fespalier.links.flavors`: `{bad}` is not a flavour name; use letters, digits and `_`, starting with a lower-case letter (the name Gradle gives it, like `prod` or `devStaging`)"
            )
        );
    }
    assert!(
        links_cfg(&[
            d,
            "flavors:",
            "  devStaging:",
            "    ios_app_id: ABCDE12345.com.example.shop"
        ])
        .is_ok()
    );
    assert_eq!(
        error_of(&[d, "flavors: {}"]),
        "`fespalier.links.flavors` is empty: list a flavour, or leave it out"
    );
    // A repeated name is read as two entries by the map, and refused.
    assert_eq!(
        error_of(&[
            d,
            "flavors:",
            "  a:",
            "    ios_app_id: ABCDE12345.com.example.shop",
            "  a:",
            "    ios_app_id: ABCDE12345.com.example.other",
        ]),
        "`fespalier.links.flavors`: `a` is listed twice"
    );
    assert_eq!(
        error_of(&[d, "flavors:", "  prod: {}"]),
        "`fespalier.links.flavors.prod` sets neither `android_package` nor `ios_app_id`"
    );
    let dup_android = error_of(&[
        d,
        "flavors:",
        "  a:",
        "    android_package: com.example.shop",
        &format!("    {sha}"),
        "  b:",
        "    android_package: com.example.shop",
        &format!("    {sha}"),
    ]);
    assert_eq!(
        dup_android,
        "`fespalier.links.flavors`: `com.example.shop` is the `android_package` of both `a` and `b`"
    );
    let dup_ios = error_of(&[
        d,
        "flavors:",
        "  a:",
        "    ios_app_id: ABCDE12345.com.example.shop",
        "  b:",
        "    ios_app_id: ABCDE12345.com.example.shop",
    ]);
    assert_eq!(
        dup_ios,
        "`fespalier.links.flavors`: `ABCDE12345.com.example.shop` is the `ios_app_id` of both `a` and `b`"
    );
    // The per-app checks name the flavour.
    assert!(
        error_of(&[
            d,
            "flavors:",
            "  prod:",
            "    android_package: com.example.shop"
        ])
        .starts_with("`fespalier.links.flavors.prod.android_package` needs `android_sha256`")
    );
    assert!(
        error_of(&[d, "flavors:", "  prod:", "    ios_app_id: nope"])
            .starts_with("`fespalier.links.flavors.prod.ios_app_id` must be the Team ID")
    );
    // A flavour can't set what is shared.
    assert!(
        Pubspec::parse(
            "name: demo\nfespalier:\n  links:\n    flavors:\n      prod:\n        domains: [a.example.com]\n"
        )
        .is_err()
    );
    assert_eq!(
        error_of(&[
            d,
            "scheme_host: false",
            "ios_app_id: ABCDE12345.com.example.shop"
        ]),
        "`fespalier.links.scheme_host` needs `scheme`"
    );
    assert_eq!(
        error_of(&[d, "paths: []"]),
        "`fespalier.links.paths` is empty: leave it out to list every linkable route"
    );
    for bad in [
        "about", "/a//b", "/a/", "/a*", "/*/a", "/a/*/b", "/a?b", "/a b", "", "/a/.", "/..",
        "/a%20b", "/a#b", "/a\\\\b",
    ] {
        assert_eq!(
            error_of(&[d, &format!("paths: ['{bad}']")]),
            format!(
                "`fespalier.links.paths`: `{bad}` is not a path pattern; write `/about` (that path) or `/orders/*` (everything below `/orders/`), starting with `/`, with `*` only as the whole last segment and no empty, `.` or `..` segment, no `?`, `#`, `%`, `\\` and no whitespace"
            ),
            "{bad}"
        );
    }
    for (bad, seg) in [
        ("/orders/:id", ":id"),
        ("/orders/$id", "$id"),
        ("/$$rest/*", "$$rest"),
    ] {
        assert_eq!(
            error_of(&[d, &format!("paths: ['{bad}']")]),
            format!(
                "`fespalier.links.paths`: `{bad}` has the segment `{seg}`; `paths:` takes no `:name` or `$name` segment, so write `*` for everything below a path (`/orders/*`)"
            ),
            "{bad}"
        );
    }
}

#[test]
fn flavours_keep_the_order_the_pubspec_writes() {
    let l = flavored();
    let names: Vec<_> = l
        .apps_ios
        .iter()
        .map(|a| a.flavor.clone().unwrap())
        .collect();
    assert_eq!(names, ["prod", "debug"]);
}

fn rest_page(name: &str) -> String {
    format!(
        "class {name}Page extends StatelessWidget {{ const {name}Page({{super.key, required this.path}}); final List<String> path; }}"
    )
}
