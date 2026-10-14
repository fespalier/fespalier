//! `AppRoutes.urlOf` (since 0.16.0): generated when `links:` has a usable first domain, and only
//! then; a section `fsp links` would refuse for its domains gets a warning and no method, and
//! `fsp gen` goes on. (The example's own `urlOf` is tested in `examples/features`.)

use std::fs;

use crate::analyze;
use crate::config::Config;

const HOME: &str = "class HomePage extends StatelessWidget { const HomePage({super.key}); }";

/// A project with `yaml` under the pubspec's name, and one page.
fn project(yaml: &str) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    fs::write(
        dir.path().join("pubspec.yaml"),
        format!("name: demo\n{yaml}"),
    )
    .unwrap();
    let p = dir.path().join("lib/app/page.dart");
    fs::create_dir_all(p.parent().unwrap()).unwrap();
    fs::write(p, HOME).unwrap();
    dir
}

/// The generated file and the diagnostics as `fsp check` shows them.
fn generated(yaml: &str) -> (String, Vec<String>) {
    let dir = project(yaml);
    let cfg = Config::load(dir.path()).unwrap();
    let (code, diags, _) = analyze(&dir.path().join("lib/app"), &cfg).unwrap();
    (code, diags.0.iter().map(ToString::to_string).collect())
}

fn links(lines: &[&str]) -> String {
    let body: String = lines.iter().map(|l| format!("    {l}\n")).collect();
    format!("fespalier:\n  links:\n{body}")
}

const URL_OF: &str = "static Uri urlOf(TypedLocation route, {String? locale}) =>";

#[test]
fn an_app_without_links_has_no_url_of() {
    let (code, diags) = generated("");
    assert!(!code.contains("urlOf"), "{code}");
    assert!(diags.is_empty(), "{diags:?}");
    // `links:` is the only key that asks for it.
    let (code, _) = generated("fespalier:\n  telemetry: true\n");
    assert!(!code.contains("urlOf"));
}

#[test]
fn the_first_domain_is_the_host_and_the_line_is_exact() {
    let (code, diags) = generated(&links(&[
        "domains: [Shop.Example.com, www.shop.example.com]",
    ]));
    assert!(diags.is_empty(), "{diags:?}");
    assert!(
        code.contains(
            "  /// The https URL of [route] on shop.example.com, the first of `fespalier: links: domains` (since 0.16.0): what a share sheet, a notification or an `og:url` gives out. [locale] picks the spelling of its localized segments (`fr-CA` falls back to `fr`); the mount prefix is in it.\n  static Uri urlOf(TypedLocation route, {String? locale}) => Uri.parse('https://shop.example.com${route.locationFor(locale)}');\n"
        ),
        "{code}"
    );
    assert_eq!(code.matches(URL_OF).count(), 1);
    // It sits right after `matchUrl`, inside `AppRoutes`.
    let at = code.find(URL_OF).unwrap();
    assert!(code[..at].contains("static UrlMatch? matchUrl(Uri uri)"));
}

#[test]
fn a_bad_android_fingerprint_with_good_domains_still_gives_url_of() {
    // Only `fsp links` checks the rest of the section.
    let (code, diags) = generated(&links(&[
        "domains: [shop.example.com]",
        "android_package: com.example.shop",
        "android_sha256: [\"AB:CD\"]",
        "ios_app_id: nope",
    ]));
    assert!(code.contains("https://shop.example.com${route.locationFor(locale)}"));
    assert!(diags.is_empty(), "{diags:?}");
}

#[test]
fn domains_that_fsp_links_refuses_give_a_warning_and_no_method() {
    let cases = [
        (
            &["scheme: myshop"][..],
            "`fespalier.links.domains` is required: list the host names the app opens, e.g. `domains: [shop.example.com]`",
        ),
        (
            &["domains: []"],
            "`fespalier.links.domains` is required: list the host names the app opens, e.g. `domains: [shop.example.com]`",
        ),
        (
            &["domains: ['https://shop.example.com/']"],
            "`fespalier.links.domains`: `https://shop.example.com/` is not a host name; write it as `shop.example.com`, with no scheme, port or path (an international name in punycode)",
        ),
        (
            &["domains: ['*.example.com', a.example.com]"],
            "`fespalier.links.domains`: the sitemap's URLs are on the first domain, so it can't be the wildcard `*.example.com`; list a host name first",
        ),
        (
            &["domains: [a.example.com, shop]"],
            "`fespalier.links.domains`: `shop` is not a host name; write it as `shop.example.com`, with no scheme, port or path (an international name in punycode)",
        ),
    ];
    for (lines, why) in cases {
        let (code, diags) = generated(&links(lines));
        assert!(!code.contains("urlOf"), "{lines:?}");
        assert_eq!(
            diags,
            [format!(
                "! pubspec.yaml  `AppRoutes.urlOf` is not generated: {why}"
            )],
            "{lines:?}"
        );
    }
}

#[test]
fn a_wildcard_after_the_first_domain_is_fine() {
    let (code, diags) = generated(&links(&["domains: [a.example.com, '*.example.com']"]));
    assert!(code.contains("https://a.example.com${route.locationFor(locale)}"));
    assert!(diags.is_empty(), "{diags:?}");
}

#[test]
fn the_warning_does_not_stop_gen() {
    let dir = project(&links(&["domains: ['*.example.com']"]));
    let outcome = crate::generate(dir.path(), true).unwrap();
    assert!(outcome.wrote);
    let out = fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap();
    assert!(!out.contains("urlOf"));
    // And a check of the file written is clean: the warning is about the pubspec, not the file.
    assert!(crate::generate(dir.path(), false).is_ok());
}
