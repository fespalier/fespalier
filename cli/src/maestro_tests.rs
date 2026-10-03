//! `fsp maestro`: the config errors, which routes get a flow and which are skipped (and why),
//! what a flow says, golden files for `examples/features`, and that the shop example's committed
//! flows are current.
//!
//! The goldens are in `tests/golden/maestro-features/`; `FSP_UPDATE_GOLDEN=1 cargo test
//! maestro_tests::` rewrites them.

use std::fs;
use std::path::{Path, PathBuf};

use crate::config::{
    Config, DEFAULT_MAESTRO_OUT, DEFAULT_MAESTRO_TIMEOUT, Maestro, Pubspec, Target,
};
use crate::maestro::{self, Flow, Skip};

fn examples(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../examples")
        .join(name)
}

/// The pubspec of an app with `lines` under `maestro:` (and `extra` as more `fespalier:` keys).
fn pubspec(extra: &[&str], lines: &[&str]) -> String {
    let more: String = extra.iter().map(|l| format!("  {l}\n")).collect();
    let body: String = lines.iter().map(|l| format!("    {l}\n")).collect();
    format!("name: demo\nfespalier:\n  semantics_ids: true\n{more}  maestro:\n{body}")
}

fn parsed(extra: &[&str], lines: &[&str]) -> anyhow::Result<Maestro> {
    let c = Pubspec::parse(&pubspec(extra, lines))?.config;
    let m = c.maestro.expect("a maestro section");
    m.validate(c.links.as_ref())
}

/// A `maestro:` section from `lines`, validated.
fn cfg(lines: &[&str]) -> anyhow::Result<Maestro> {
    parsed(&[], lines)
}

fn error_of(lines: &[&str]) -> String {
    format!("{:#}", cfg(lines).unwrap_err())
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

fn app_of(project: &Path) -> crate::resolve::App {
    let cfg = Config::load(project).unwrap();
    let (_, diags, app) = crate::analyze(&project.join(&cfg.app_dir), &cfg).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    app
}

fn page(name: &str) -> String {
    format!("class {name}Page extends StatelessWidget {{ const {name}Page({{super.key}}); }}")
}

fn typed_page(name: &str, param: &str, ty: &str) -> String {
    format!(
        "class {name}Page extends StatelessWidget {{ const {name}Page({{super.key, required this.{param}}}); final {ty} {param}; }}"
    )
}

const GUARD: &str = "String? guard(Ref ref) => null;";

/// The flows and the skips of a project's tree with `lines` as its `maestro:` section.
fn run_with(files: &[(&str, &str)], lines: &[&str]) -> anyhow::Result<(Vec<Flow>, Vec<Skip>)> {
    let dir = project(files);
    let app = app_of(dir.path());
    let c = Pubspec::parse(&pubspec(&[], lines)).unwrap().config;
    let m = c.maestro.clone().unwrap().validate(None)?;
    maestro::flows(&app, &c, &m)
}

fn flows_of(files: &[(&str, &str)], lines: &[&str]) -> (Vec<Flow>, Vec<Skip>) {
    run_with(files, lines).unwrap()
}

fn skipped(skips: &[Skip]) -> Vec<String> {
    skips
        .iter()
        .map(|s| format!("{}: {}", s.pattern, s.reason))
        .collect()
}

fn names(flows: &[Flow]) -> Vec<&str> {
    flows.iter().map(|f| f.file.as_str()).collect()
}

fn text<'a>(flows: &'a [Flow], file: &str) -> &'a str {
    &flows
        .iter()
        .find(|f| f.file == file)
        .unwrap_or_else(|| panic!("no {file} in {:?}", names(flows)))
        .text
}

const APP: &str = "app_id: com.example.shop";
const WEB: &str = "url: http://localhost:8080";
const LINK: &str = "link: myshop://shop.example.com";

// --- the config -----------------------------------------------------------------

#[test]
fn the_defaults() {
    let m = cfg(&[APP, LINK]).unwrap();
    assert_eq!(m.target, Target::App("com.example.shop".into()));
    assert_eq!(m.link, "myshop://shop.example.com");
    assert_eq!(m.out, DEFAULT_MAESTRO_OUT);
    assert_eq!(m.out, ".maestro/routes");
    assert_eq!(m.timeout, DEFAULT_MAESTRO_TIMEOUT);
    assert_eq!(m.timeout, 20_000);
    assert_eq!(m.guard_flow, None);
    assert!(m.samples.is_empty());
    assert!(!m.https_app_link);
}

#[test]
fn neither_app_id_nor_url_is_an_error() {
    assert_eq!(
        error_of(&[LINK]),
        "`fespalier.maestro` needs `app_id` (Android and iOS) or `url` (the web): what each flow's `appId:` or `url:` is"
    );
}

#[test]
fn both_app_id_and_url_is_an_error() {
    assert_eq!(
        error_of(&[APP, WEB]),
        "`fespalier.maestro` takes `app_id` or `url`, not both: a flow is for Android and iOS or for the web"
    );
}

#[test]
fn an_app_id_is_checked() {
    for bad in [
        "shop",
        "com..shop",
        "1com.shop",
        "com.sh op",
        "com.example.",
        "com.sh$op",
    ] {
        assert_eq!(
            error_of(&[&format!("app_id: '{bad}'"), LINK]),
            format!(
                "`fespalier.maestro.app_id` must be an application or bundle id like `com.example.shop`, or a Maestro variable like `${{APP_ID}}`, got `{bad}`"
            )
        );
    }
    for good in ["com.example.shop", "com.example.my-shop", "org.a_b.c1"] {
        assert!(cfg(&[&format!("app_id: {good}"), LINK]).is_ok(), "{good}");
    }
}

#[test]
fn a_url_is_checked() {
    for bad in [
        "localhost:8080",
        "ftp://localhost",
        "http://",
        "http:///x",
        "http://local host",
        "http://localhost:8080/?a=1",
        "http://localhost:8080/#/x",
    ] {
        assert_eq!(
            error_of(&[&format!("url: '{bad}'")]),
            format!(
                "`fespalier.maestro.url` must be an http or https URL like `http://localhost:8080`, or a Maestro variable like `${{URL}}`, got `{bad}`"
            ),
            "{bad}"
        );
    }
    assert!(cfg(&["url: https://shop.example.com/app"]).is_ok());
}

#[test]
fn a_link_is_checked() {
    for bad in [
        "shop.example.com",
        "myshop://",
        "myshop://a b",
        "myshop://shop?x=1",
        "myshop://shop/#/x",
        "1shop://x",
    ] {
        assert_eq!(
            error_of(&[APP, &format!("link: '{bad}'")]),
            format!(
                "`fespalier.maestro.link` must be a URL like `myshop://shop.example.com` or `http://localhost:8080/#`, with no query, or a Maestro variable like `${{LINK}}`, got `{bad}`"
            ),
            "{bad}"
        );
    }
}

#[test]
fn a_link_loses_one_trailing_slash_and_keeps_a_hash() {
    let link = |l: &str| cfg(&[WEB, &format!("link: '{l}'")]).unwrap().link;
    assert_eq!(link("http://localhost:8080/"), "http://localhost:8080");
    assert_eq!(link("http://localhost:8080/#"), "http://localhost:8080/#");
    assert_eq!(
        link("myshop://shop.example.com"),
        "myshop://shop.example.com"
    );
}

#[test]
fn a_maestro_variable_is_taken_for_app_id_url_and_link() {
    let m = cfg(&["app_id: ${APP_ID}", "link: ${LINK}"]).unwrap();
    assert_eq!(m.target, Target::App("${APP_ID}".into()));
    assert_eq!(m.link, "${LINK}");
    assert!(!m.https_app_link);
    let m = cfg(&["url: ${URL}"]).unwrap();
    assert_eq!(m.target, Target::Web("${URL}".into()));
    assert_eq!(m.link, "${URL}");
    // Only a whole variable counts.
    assert!(error_of(&["app_id: ${1X}", LINK]).starts_with("`fespalier.maestro.app_id`"));
    assert!(error_of(&["app_id: 'x${A}'", LINK]).starts_with("`fespalier.maestro.app_id`"));
}

#[test]
fn the_link_defaults_to_the_url_on_the_web() {
    assert_eq!(cfg(&[WEB]).unwrap().link, "http://localhost:8080");
    assert_eq!(
        cfg(&["url: http://localhost:8080/"]).unwrap().link,
        "http://localhost:8080"
    );
}

#[test]
fn the_link_of_an_app_defaults_from_links() {
    let m = parsed(
        &[
            "links:",
            "  domains: [shop.example.com]",
            "  scheme: myshop",
        ],
        &[APP],
    );
    // `links:` takes a platform to put the scheme in.
    assert!(m.is_err());
    let m = parsed(
        &[
            "links:",
            "  domains: [shop.example.com]",
            "  scheme: myshop",
            "  ios_app_id: ABCDE12345.com.example.shop",
        ],
        &[APP],
    )
    .unwrap();
    assert_eq!(m.link, "myshop://shop.example.com");
    assert!(!m.https_app_link);
    let m = parsed(&["links:", "  domains: [shop.example.com]"], &[APP]).unwrap();
    assert_eq!(m.link, "https://shop.example.com");
    assert!(m.https_app_link);
    // A `link:` of its own wins, and `links:` is not even checked.
    let m = parsed(&["links:", "  domains: []"], &[APP, LINK]).unwrap();
    assert_eq!(m.link, "myshop://shop.example.com");
}

#[test]
fn an_app_needs_a_link_or_links() {
    assert_eq!(
        error_of(&[APP]),
        "`fespalier.maestro.link` is required with `app_id` when there is no `links:` section: write what a route's path goes after, e.g. `link: myshop://shop.example.com`"
    );
}

#[test]
fn a_broken_links_section_is_reported_as_it_is() {
    let e = parsed(&["links:", "  domains: ['not a host']"], &[APP]).unwrap_err();
    assert!(
        format!("{e:#}").starts_with("`fespalier.links.domains`: `not a host` is not a host name"),
        "{e:#}"
    );
}

#[test]
fn out_is_a_folder_inside_the_project() {
    for bad in ["/abs", "../x", "a/../../b", "C:\\x", "''"] {
        assert_eq!(
            error_of(&[WEB, &format!("out: {bad}")]).replace('\'', ""),
            format!(
                "`fespalier.maestro.out` must be a folder inside the project (relative, no `..`), got `{}`",
                bad.replace('\'', "")
            ),
            "{bad}"
        );
    }
    assert_eq!(cfg(&[WEB, "out: ./e2e/flows/"]).unwrap().out, "e2e/flows");
    assert_eq!(cfg(&[WEB, "out: ."]).unwrap().out, "");
}

#[test]
fn the_links_out_message_is_unchanged() {
    let c = Pubspec::parse(
        "name: demo\nfespalier:\n  links:\n    domains: [a.example.com]\n    out: ../x\n",
    )
    .unwrap()
    .config;
    let e = c.links.unwrap().validate().unwrap_err();
    assert_eq!(
        e.to_string(),
        "`fespalier.links.out` must be a folder inside the project (relative, no `..`), got `../x`"
    );
}

#[test]
fn guard_flow_is_a_yaml_file_inside_the_project() {
    for bad in [
        "/abs.yaml",
        "../x.yaml",
        "sign-in.json",
        ".maestro",
        ".yaml",
        "''",
    ] {
        assert_eq!(
            error_of(&[WEB, &format!("guard_flow: {bad}")]).replace('\'', ""),
            format!(
                "`fespalier.maestro.guard_flow` must be a .yaml or .yml file inside the project (relative, no `..`), got `{}`",
                bad.replace('\'', "")
            ),
            "{bad}"
        );
    }
    assert_eq!(
        cfg(&[WEB, "guard_flow: ./.maestro/sign-in.yml"])
            .unwrap()
            .guard_flow
            .as_deref(),
        Some(".maestro/sign-in.yml")
    );
}

#[test]
fn timeout_is_in_milliseconds_from_one_second_to_ten_minutes() {
    for bad in ["0", "999", "600001", "-5"] {
        assert_eq!(
            error_of(&[WEB, &format!("timeout: {bad}")]),
            format!(
                "`fespalier.maestro.timeout` is in milliseconds, from 1000 to 600000, got `{bad}`"
            )
        );
    }
    assert_eq!(cfg(&[WEB, "timeout: 1000"]).unwrap().timeout, 1000);
    assert_eq!(cfg(&[WEB, "timeout: 600000"]).unwrap().timeout, 600_000);
}

#[test]
fn a_sample_is_a_text_a_number_a_boolean_or_a_list_of_them() {
    for bad in ["~", "{a: 1}", "[[1]]", "[1, {a: 2}]"] {
        assert_eq!(
            error_of(&[WEB, "samples:", &format!("  a/$id: {bad}")]),
            "`fespalier.maestro.samples`: the value of `a/$id` must be a text, a number, a boolean or a list of them",
            "{bad}"
        );
    }
    let m = cfg(&[
        WEB,
        "samples:",
        "  a/$id: 1.5",
        "  b/$id: true",
        "  c/$$x: [a, 2]",
    ])
    .unwrap();
    use crate::config::SampleValue::{Many, One};
    assert_eq!(
        m.samples,
        [
            ("a/$id".to_string(), One("1.5".into())),
            ("b/$id".to_string(), One("true".into())),
            ("c/$$x".to_string(), Many(vec!["a".into(), "2".into()])),
        ]
    );
}

#[test]
fn an_unknown_key_is_an_error_everywhere_and_a_bad_value_only_for_maestro() {
    let e = Pubspec::parse(&pubspec(&[], &[WEB, "appid: x"])).unwrap_err();
    assert!(format!("{e:#}").contains("unknown field `appid`"), "{e:#}");
    // `fsp gen` reads the section but never checks its values.
    let p = Pubspec::parse(&pubspec(&[], &["app_id: nope"])).unwrap();
    assert!(p.config.maestro.is_some());
    assert!(p.config.semantics_ids);
}

#[test]
fn the_top_level_unknown_key_message_lists_semantics_ids_telemetry_and_maestro() {
    let e = format!(
        "{:#}",
        Pubspec::parse("name: demo\nfespalier:\n  maestr: {}\n").unwrap_err()
    );
    assert!(
        e.contains("unknown field `maestr`")
            && e.contains(
                "`links`, `lints`, `semantics_ids`, `scroll_restoration`, `telemetry`, `maestro`"
            ),
        "{e}"
    );
}

// --- which routes get a flow ----------------------------------------------------

#[test]
fn a_flow_per_page_named_after_its_route_class() {
    let (flows, skips) = flows_of(
        &[
            ("page.dart", &page("Home")),
            ("about/page.dart", &page("About")),
            ("(plans)/pro/page.dart", &page("ProPlan")),
        ],
        &[WEB],
    );
    assert!(skips.is_empty());
    assert_eq!(
        names(&flows),
        ["home_route.yaml", "pro_plan_route.yaml", "about_route.yaml"]
    );
    assert!(text(&flows, "pro_plan_route.yaml").contains("      id: \"route:/pro\"\n"));
}

#[test]
fn file_names_are_the_snake_case_route_class() {
    // The route class is the page class without `Page`, and `Route` after it.
    let (flows, _) = flows_of(
        &[
            ("a/page.dart", &page("ProductDetail")),
            ("b/page.dart", &page("Cart2Items")),
            ("c/page.dart", &page("Sub")),
        ],
        &[WEB],
    );
    assert_eq!(
        names(&flows),
        [
            "product_detail_route.yaml",
            "cart2_items_route.yaml",
            "sub_route.yaml"
        ]
    );
}

#[test]
fn a_redirect_has_no_page_to_see() {
    let (flows, skips) = flows_of(
        &[
            ("page.dart", &page("Home")),
            ("old/redirect.dart", "String redirect() => '/';"),
        ],
        &[WEB],
    );
    assert_eq!(names(&flows), ["home_route.yaml"]);
    assert_eq!(skipped(&skips), ["/old: a redirect, with no page to see"]);
}

#[test]
fn a_route_that_is_not_linkable_is_skipped_for_an_app_and_written_for_the_web() {
    let files = [
        ("page.dart", page("Home")),
        ("secret/page.dart", page("Secret")),
        ("secret/route.dart", "const linkable = false;".to_string()),
    ];
    let files: Vec<(&str, &str)> = files.iter().map(|(a, b)| (*a, b.as_str())).collect();
    let (flows, skips) = flows_of(&files, &[APP, LINK]);
    assert_eq!(names(&flows), ["home_route.yaml"]);
    assert_eq!(
        skipped(&skips),
        ["/secret: `const linkable = false;`, so `fsp links` does not open the app at it"]
    );
    let (flows, skips) = flows_of(&files, &[WEB]);
    assert_eq!(names(&flows), ["home_route.yaml", "secret_route.yaml"]);
    assert!(skips.is_empty());
}

#[test]
fn a_dynamic_segment_without_a_sample_skips_the_route() {
    let files = [
        ("page.dart", page("Home")),
        ("products/$id/page.dart", typed_page("Product", "id", "int")),
        (
            "docs/$$rest/page.dart",
            typed_page("Docs", "rest", "List<String>"),
        ),
        (
            "files/$$$path/page.dart",
            typed_page("Files", "path", "List<String>"),
        ),
        (
            "products/$id/reviews/$n/page.dart",
            typed_page("Review", "n", "int"),
        ),
    ];
    let files: Vec<(&str, &str)> = files.iter().map(|(a, b)| (*a, b.as_str())).collect();
    let (flows, skips) = flows_of(&files, &[WEB, "samples:", "  products/$id: 3"]);
    assert_eq!(
        skipped(&skips),
        [
            "/docs/*rest: no sample for docs/$$rest in `fespalier.maestro.samples`",
            "/products/:id/reviews/:n: no sample for products/$id/reviews/$n in `fespalier.maestro.samples`",
        ]
    );
    // An optional catch-all with no sample is the bare path, so its route still has a flow.
    assert_eq!(
        names(&flows),
        ["home_route.yaml", "files_route.yaml", "product_route.yaml"]
    );
    assert!(
        text(&flows, "files_route.yaml").contains("- openLink: \"http://localhost:8080/files\"\n")
    );
    assert!(
        text(&flows, "product_route.yaml")
            .contains("- openLink: \"http://localhost:8080/products/3\"\n")
    );
}

#[test]
fn a_sample_is_inherited_by_the_routes_below_its_folder() {
    let files = [
        ("products/$id/page.dart", typed_page("Product", "id", "int")),
        ("products/$id/reviews/page.dart", page("Reviews")),
    ];
    let files: Vec<(&str, &str)> = files.iter().map(|(a, b)| (*a, b.as_str())).collect();
    let (flows, skips) = flows_of(&files, &[WEB, "samples:", "  products/$id: 3"]);
    assert!(skips.is_empty());
    assert!(text(&flows, "reviews_route.yaml").contains("/products/3/reviews\"\n"));
}

#[test]
fn a_guarded_route_needs_a_guard_flow() {
    let files = [
        ("page.dart", page("Home")),
        ("(members)/guard.dart", GUARD.to_string()),
        ("(members)/inbox/page.dart", page("Inbox")),
        ("(members)/admin/guard.dart", GUARD.to_string()),
        ("(members)/admin/page.dart", page("Admin")),
        ("open/page.dart", page("Open")),
    ];
    let files: Vec<(&str, &str)> = files.iter().map(|(a, b)| (*a, b.as_str())).collect();
    let (flows, skips) = flows_of(&files, &[WEB]);
    assert_eq!(names(&flows), ["home_route.yaml", "open_route.yaml"]);
    // The guards above a route, outermost first, as `fsp routes` would name them.
    assert_eq!(
        skipped(&skips),
        [
            "/admin: guarded by (members)/guard.dart, (members)/admin/guard.dart; set `fespalier.maestro.guard_flow` to a flow that gets past it",
            "/inbox: guarded by (members)/guard.dart; set `fespalier.maestro.guard_flow` to a flow that gets past it",
        ]
    );

    let guard = &["guard_flow: .maestro/sign-in.yaml"];
    let lines: Vec<&str> = [&[WEB][..], guard].concat();
    let (flows, skips) = flows_of(&files, &lines);
    assert!(skips.is_empty());
    assert_eq!(
        names(&flows),
        [
            "home_route.yaml",
            "admin_route.yaml",
            "inbox_route.yaml",
            "open_route.yaml"
        ]
    );
    let admin = text(&flows, "admin_route.yaml");
    assert!(
        admin.contains(
            "# Guarded by (members)/guard.dart, (members)/admin/guard.dart: ../sign-in.yaml runs before the link.\n"
        ),
        "{admin}"
    );
    assert!(
        admin.contains("- launchApp\n- runFlow: \"../sign-in.yaml\"\n- openLink:"),
        "{admin}"
    );
    // A route nothing guards does not sign in.
    assert!(!text(&flows, "open_route.yaml").contains("runFlow"));
    assert!(!text(&flows, "home_route.yaml").contains("runFlow"));
}

#[test]
fn the_first_row_that_applies_wins() {
    // A redirect is a redirect before it is anything else; a missing sample comes before a guard.
    let files = [
        ("page.dart", page("Home")),
        ("g/guard.dart", GUARD.to_string()),
        ("g/$id/page.dart", typed_page("G", "id", "int")),
    ];
    let files: Vec<(&str, &str)> = files.iter().map(|(a, b)| (*a, b.as_str())).collect();
    let (_, skips) = flows_of(&files, &[WEB]);
    assert_eq!(
        skipped(&skips),
        ["/g/:id: no sample for g/$id in `fespalier.maestro.samples`"]
    );
}

#[test]
fn nothing_to_open_is_an_error_and_everything_skipped_is_not() {
    let e = run_with(&[("route.dart", "const linkable = false;")], &[WEB]).unwrap_err();
    assert_eq!(
        e.to_string(),
        "no route has a page: there is nothing for a flow to open"
    );
    let (flows, skips) = flows_of(
        &[("p/$id/page.dart", &typed_page("P", "id", "int"))],
        &[WEB],
    );
    assert!(flows.is_empty());
    assert_eq!(skips.len(), 1);
}

// --- the samples ----------------------------------------------------------------

fn sample_error(files: &[(&str, &str)], samples: &[&str]) -> String {
    let mut lines = vec![WEB, "samples:"];
    lines.extend(samples);
    format!("{:#}", run_with(files, &lines).unwrap_err())
}

#[test]
fn a_sample_names_a_dynamic_folder() {
    let int_page = typed_page("P", "id", "int");
    let files = [
        ("p/$id/page.dart", int_page.as_str()),
        (
            "about/page.dart",
            "class AboutPage extends StatelessWidget { const AboutPage({super.key}); }",
        ),
    ];
    assert_eq!(
        sample_error(&files, &["  q/$id: 1"]),
        "`fespalier.maestro.samples`: `q/$id` is not a folder of lib/app; write it as `fsp routes` prints it, without `/page.dart` (`products/$id`)"
    );
    assert_eq!(
        sample_error(&files, &["  about: 1"]),
        "`fespalier.maestro.samples`: `about` is not a `$segment` folder; samples give the values of dynamic segments"
    );
}

#[test]
fn a_sample_has_the_right_shape_and_type() {
    let int_page = typed_page("P", "id", "int");
    let list_page = typed_page("L", "ids", "List<int>");
    let double_page = typed_page("D", "x", "double");
    let bool_page = typed_page("B", "on", "bool");
    let str_page = typed_page("S", "name", "String");
    let files = [
        ("p/$id/page.dart", int_page.as_str()),
        ("l/$$ids/page.dart", list_page.as_str()),
        ("d/$x/page.dart", double_page.as_str()),
        ("b/$on/page.dart", bool_page.as_str()),
        ("s/$name/page.dart", str_page.as_str()),
    ];
    assert_eq!(
        sample_error(&files, &["  p/$id: abc"]),
        "`fespalier.maestro.samples`: `p/$id` is a `int` segment, and `abc` is not one"
    );
    assert_eq!(
        sample_error(&files, &["  p/$id: [1, 2]"]),
        "`fespalier.maestro.samples`: `p/$id` is one segment; give one value, not a list"
    );
    assert_eq!(
        sample_error(&files, &["  l/$$ids: [1, two]"]),
        "`fespalier.maestro.samples`: `l/$$ids` is a `List<int>` segment, and `two` is not one"
    );
    assert_eq!(
        sample_error(&files, &["  l/$$ids: []"]),
        "`fespalier.maestro.samples`: `l/$$ids` is a catch-all that needs at least one part"
    );
    assert_eq!(
        sample_error(&files, &["  d/$x: nan"]),
        "`fespalier.maestro.samples`: `d/$x` is a `double` segment, and `nan` is not one"
    );
    assert_eq!(
        sample_error(&files, &["  b/$on: yes", "  s/$name: x"]),
        "`fespalier.maestro.samples`: `b/$on` is a `bool` segment, and `yes` is not one"
    );
    assert_eq!(
        sample_error(&files, &["  s/$name: ''"]),
        "`fespalier.maestro.samples`: `s/$name` is empty; a segment can't be"
    );
    assert_eq!(
        sample_error(&files, &["  l/$$ids: ['1', '']"]),
        "`fespalier.maestro.samples`: `l/$$ids` is empty; a segment can't be"
    );
    // What is right is taken: a lone scalar for a catch-all is one part.
    let (flows, _) = flows_of(
        &files,
        &[
            WEB,
            "samples:",
            "  p/$id: 7",
            "  l/$$ids: 5",
            "  d/$x: 1.5",
            "  b/$on: true",
            "  s/$name: Ada",
        ],
    );
    assert!(text(&flows, "l_route.yaml").contains("/l/5\"\n"));
    assert!(text(&flows, "d_route.yaml").contains("/d/1.5\"\n"));
    assert!(text(&flows, "b_route.yaml").contains("/b/true\"\n"));
}

#[test]
fn link_paths_are_percent_encoded_and_catch_alls_joined() {
    let str_page = typed_page("S", "name", "String");
    let rest_page = typed_page("Docs", "rest", "List<String>");
    let files = [
        ("s/$name/page.dart", str_page.as_str()),
        ("docs/$$rest/page.dart", rest_page.as_str()),
    ];
    let (flows, _) = flows_of(
        &files,
        &[
            WEB,
            "samples:",
            "  s/$name: a b/ü",
            "  docs/$$rest: [guides, 'in tro']",
        ],
    );
    let s = text(&flows, "s_route.yaml");
    assert!(
        s.contains("- openLink: \"http://localhost:8080/s/a%20b%2F%C3%BC\"\n"),
        "{s}"
    );
    let docs = text(&flows, "docs_route.yaml");
    assert!(docs.contains("/docs/guides/in%20tro\"\n"), "{docs}");
}

#[test]
fn a_localized_route_is_opened_at_its_canonical_path() {
    let files = [
        ("guide/page.dart", page("Guide")),
        (
            "guide/route.dart",
            "const paths = {'de': 'führer'};".to_string(),
        ),
    ];
    let files: Vec<(&str, &str)> = files.iter().map(|(a, b)| (*a, b.as_str())).collect();
    let (flows, _) = flows_of(&files, &[WEB]);
    let t = text(&flows, "guide_route.yaml");
    assert!(
        t.contains("openLink: \"http://localhost:8080/guide\""),
        "{t}"
    );
    assert!(!t.contains("hrer"), "{t}");
}

// --- what a flow says -----------------------------------------------------------

#[test]
fn a_web_flow_has_a_url_and_no_auto_verify() {
    let (flows, _) = flows_of(
        &[("page.dart", &page("Home"))],
        &[WEB, "link: http://localhost:8080/#"],
    );
    assert_eq!(
        text(&flows, "home_route.yaml"),
        "# Written by `fsp maestro` from lib/app/page.dart: don't edit it, run `fsp maestro` again.\n\
url: \"http://localhost:8080\"\n\
name: \"/\"\n\
tags:\n  - \"fespalier\"\n\
---\n\
- launchApp\n\
- openLink: \"http://localhost:8080/#/\"\n\
- extendedWaitUntil:\n    visible:\n      id: \"route:/\"\n    timeout: 20000\n"
    );
}

#[test]
fn an_app_flow_has_an_app_id_and_a_timeout_of_its_own() {
    let (flows, _) = flows_of(
        &[("products/page.dart", &page("Products"))],
        &[APP, LINK, "timeout: 5000"],
    );
    assert_eq!(
        text(&flows, "products_route.yaml"),
        "# Written by `fsp maestro` from lib/app/products/page.dart: don't edit it, run `fsp maestro` again.\n\
appId: \"com.example.shop\"\n\
name: \"/products\"\n\
tags:\n  - \"fespalier\"\n\
---\n\
- launchApp\n\
- openLink: \"myshop://shop.example.com/products\"\n\
- extendedWaitUntil:\n    visible:\n      id: \"route:/products\"\n    timeout: 5000\n"
    );
}

#[test]
fn https_app_link_uses_auto_verify() {
    let (flows, _) = flows_of(
        &[("products/page.dart", &page("Products"))],
        &[APP, "link: https://shop.example.com"],
    );
    let t = text(&flows, "products_route.yaml");
    assert!(
        t.contains(
            "- openLink:\n    link: \"https://shop.example.com/products\"\n    autoVerify: true\n"
        ),
        "{t}"
    );
    // On the web it is a plain `openLink`, whatever the link says.
    let (flows, _) = flows_of(
        &[("products/page.dart", &page("Products"))],
        &["url: https://shop.example.com"],
    );
    let t = text(&flows, "products_route.yaml");
    assert!(!t.contains("autoVerify"), "{t}");
    assert!(
        t.contains("- openLink: \"https://shop.example.com/products\"\n"),
        "{t}"
    );
}

#[test]
fn what_yaml_would_read_specially_is_quoted() {
    let files = [("s/$name/page.dart", typed_page("S", "name", "String"))];
    let files: Vec<(&str, &str)> = files.iter().map(|(a, b)| (*a, b.as_str())).collect();
    let (flows, _) = flows_of(
        &files,
        &[
            "app_id: ${APP_ID}",
            "link: ${LINK}",
            "samples:",
            "  s/$name: '# a: b'",
        ],
    );
    let t = text(&flows, "s_route.yaml");
    assert!(t.contains("appId: \"${APP_ID}\"\n"), "{t}");
    assert!(
        t.contains("- openLink: \"${LINK}/s/%23%20a%3A%20b\"\n"),
        "{t}"
    );
    assert!(t.contains("name: \"/s/:name\"\n"), "{t}");
}

#[test]
fn guard_flow_path_is_relative_to_the_flow() {
    let files = [
        ("g/guard.dart", GUARD.to_string()),
        ("g/page.dart", page("G")),
    ];
    let files: Vec<(&str, &str)> = files.iter().map(|(a, b)| (*a, b.as_str())).collect();
    let run_flow = |out: &str, guard: &str| {
        let (flows, _) = flows_of(
            &files,
            &[WEB, &format!("out: {out}"), &format!("guard_flow: {guard}")],
        );
        text(&flows, "g_route.yaml")
            .lines()
            .find(|l| l.starts_with("- runFlow: "))
            .unwrap()
            .to_string()
    };
    assert_eq!(
        run_flow(".maestro/routes", ".maestro/sign-in.yaml"),
        "- runFlow: \"../sign-in.yaml\""
    );
    assert_eq!(
        run_flow("e2e", "e2e/login.yaml"),
        "- runFlow: \"login.yaml\""
    );
    assert_eq!(
        run_flow("e2e/flows", "e2e/auth/login.yaml"),
        "- runFlow: \"../auth/login.yaml\""
    );
    assert_eq!(run_flow(".", "login.yaml"), "- runFlow: \"login.yaml\"");
}

#[test]
fn the_output_is_the_same_bytes_every_time() {
    let run = || {
        let (flows, skips) = flows_of(
            &[
                ("page.dart", page("Home")),
                ("a/page.dart", page("A")),
                ("b/$id/page.dart", typed_page("B", "id", "int")),
            ]
            .iter()
            .map(|(a, b)| (*a, b.as_str()))
            .collect::<Vec<_>>(),
            &[WEB, "samples:", "  b/$id: 2"],
        );
        (flows, skips)
    };
    assert_eq!(run(), run());
}

// --- examples ---------------------------------------------------------------------

/// A `maestro:` for `examples/features`, leaving `wiki/$$article` and the `remount` folders
/// without a sample on purpose.
const FEATURES: &[&str] = &[
    "app_id: com.example.features",
    "link: features://app.example.com",
    "guard_flow: .maestro/sign-in.yaml",
    "samples:",
    "  $slug: hello",
    "  browse/$$categories: [a, b]",
    "  catalog/$productId: 7",
    "  compare/$$ids: [1, 2]",
    "  docs/$$rest: [guides, intro]",
    "  help/$topic: start",
    "  notes/$id: 3",
    "  orders/$id: 5",
    "  photos/$id: 9",
    "  shop/$category: shoes",
    "  shops/$shop: acme",
    "  shops/$shop/items/$id: 4",
    "  teams/$teamId: 1",
    "  teams/$teamId/members/$member: 2",
];

fn features() -> (Vec<Flow>, Vec<Skip>) {
    let dir = examples("features");
    let app = app_of(&dir);
    let cfg = Config::load(&dir).unwrap();
    let c = Pubspec::parse(&pubspec(&[], FEATURES)).unwrap().config;
    let m = c.maestro.unwrap().validate(None).unwrap();
    maestro::flows(&app, &cfg, &m).unwrap()
}

#[test]
fn goldens_of_examples_features() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/golden/maestro-features");
    let update = std::env::var_os("FSP_UPDATE_GOLDEN").is_some();
    let (flows, skips) = features();
    assert!(flows.len() > 30, "{}", flows.len());
    for f in &flows {
        let golden = root.join(&f.file);
        if update {
            fs::create_dir_all(&root).unwrap();
            fs::write(&golden, &f.text).unwrap();
        }
        let want = fs::read_to_string(&golden).unwrap_or_default();
        assert_eq!(
            f.text,
            want,
            "{} is stale; run `FSP_UPDATE_GOLDEN=1 cargo test maestro_tests::` in cli/",
            golden.display()
        );
    }
    // No golden is left over from a route that has gone.
    let mut on_disk: Vec<String> = fs::read_dir(&root)
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    on_disk.sort();
    let mut want = names(&flows)
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>();
    want.sort();
    assert_eq!(on_disk, want, "a golden with no route; delete it");
    assert_eq!(
        skipped(&skips),
        [
            "/old-search: a redirect, with no page to see",
            "/old-shops/:shop: a redirect, with no page to see",
            "/remount/location/:id: no sample for remount/location/$id in `fespalier.maestro.samples`",
            "/remount/never/:id: no sample for remount/never/$id in `fespalier.maestro.samples`",
            "/remount/segments/:id: no sample for remount/segments/$id in `fespalier.maestro.samples`",
            "/wiki/*article: no sample for wiki/$$article in `fespalier.maestro.samples`",
        ]
    );
}

#[test]
fn committed_shop_flows_are_up_to_date() {
    let dir = examples("shop");
    let cfg = Config::load(&dir).unwrap();
    let app = app_of(&dir);
    let m = cfg
        .maestro
        .clone()
        .expect("examples/shop has a maestro: section")
        .validate(cfg.links.as_ref())
        .unwrap();
    let (flows, skips) = maestro::flows(&app, &cfg, &m).unwrap();
    let out = dir.join(&m.out);
    for f in &flows {
        let disk = fs::read_to_string(out.join(&f.file)).unwrap_or_default();
        assert_eq!(
            f.text, disk,
            "{} is stale; run `fsp maestro --project examples/shop`",
            f.file
        );
    }
    let mut owned: Vec<String> = fs::read_dir(&out)
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .filter(|n| {
            fs::read_to_string(out.join(n))
                .is_ok_and(|t| t.starts_with("# Written by `fsp maestro`"))
        })
        .collect();
    owned.sort();
    let mut want: Vec<String> = flows.iter().map(|f| f.file.clone()).collect();
    want.sort();
    assert_eq!(
        owned, want,
        "a flow with no route; run `fsp maestro --project examples/shop`"
    );
    // The example shows a skip: /checkout is guarded and there is no guard_flow.
    assert_eq!(
        skipped(&skips),
        [
            "/checkout: guarded by checkout/guard.dart; set `fespalier.maestro.guard_flow` to a flow that gets past it"
        ]
    );
}
