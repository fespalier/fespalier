//! `fsp size` (since 0.8.1): reading dart2js's table of deferred parts out of `main.dart.js`, which
//! bytes belong to which deferred route, the stale-build checks, and the `size:` budgets.
//!
//! The build is `tests/fixtures/shop-build/main.dart.js`, a trimmed excerpt of a real
//! `flutter build web --release` of `examples/shop`, with part files of the lengths that build
//! had (1,090, 4,169 and 1,813 bytes) written next to it, and `examples/shop` as the project.

use std::fs::{self, File};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use crate::config::{Config, Pubspec, Size};
use crate::size::{self, Report, Table, Unreadable, parse_table};
use crate::{analyze, build};

/// The release text of the table, verbatim from a build of `examples/shop`.
const MINIFIED: &str = r#"deferredLibraryParts:{_i7:[0,1],_i14:[0,2]},
deferredPartUris:["main.dart.js_2.part.js","main.dart.js_1.part.js","main.dart.js_3.part.js"],
deferredPartHashes:["bubiL8EZQZtYrGwZbSp7fiNxg8Y=","ZjjiGRXq0tw0DeMz4JyzRuAgLLY=","WKqwSmeoYm2VbjxW0TniJ47ghXU="],"#;

/// The profile build's text of the same table (not minified).
const PROFILE: &str = r#"    deferredLibraryParts: {
      _i7: [0, 1],
      _i14: [0, 2]
    },
    deferredPartUris: ["main.dart.js_2.part.js", "main.dart.js_1.part.js", "main.dart.js_3.part.js"],
    deferredPartHashes: ["a", "b", "c"],
"#;

fn shop() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../examples/shop")
}

fn fixture_js() -> String {
    fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/shop-build/main.dart.js"),
    )
    .unwrap()
}

fn table() -> Table {
    Table {
        uris: vec![
            "main.dart.js_2.part.js".into(),
            "main.dart.js_1.part.js".into(),
            "main.dart.js_3.part.js".into(),
        ],
        libs: vec![("_i7".into(), vec![0, 1]), ("_i14".into(), vec![0, 2])],
    }
}

/// A build folder with `js` as main.dart.js and the shop's three part files.
fn build_dir(js: &str) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("main.dart.js"), js).unwrap();
    for (n, len) in [(1, 1090), (2, 4169), (3, 1813)] {
        fs::write(
            dir.path().join(format!("main.dart.js_{n}.part.js")),
            vec![b'x'; len],
        )
        .unwrap();
    }
    dir
}

fn set_modified(path: &Path, to: SystemTime) {
    File::options()
        .write(true)
        .open(path)
        .unwrap()
        .set_modified(to)
        .unwrap();
}

/// A build `main.dart.js` that is newer than the shop's generated file.
fn make_newer(dir: &Path) {
    set_modified(
        &dir.join("main.dart.js"),
        SystemTime::now() + Duration::from_hours(1),
    );
}

fn shop_size() -> (Config, Size) {
    let cfg = Config::load(&shop()).unwrap();
    let size = cfg.size.as_ref().unwrap().validate().unwrap();
    (cfg, size)
}

/// The shop's report from the build in `dir`.
fn shop_report(dir: &Path) -> anyhow::Result<(Report, Option<String>)> {
    let (cfg, size) = shop_size();
    let (_, diags, app) = analyze(&shop().join(&cfg.app_dir), &cfg).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    size::report(&app, &cfg, &size, &shop(), dir, "build/web")
}

fn error_of(js: &str) -> String {
    let dir = build_dir(js);
    make_newer(dir.path());
    format!("{:#}", shop_report(dir.path()).unwrap_err())
}

// The table parser.

#[test]
fn reads_the_release_table() {
    assert_eq!(parse_table(MINIFIED), Ok(Some(table())));
}

#[test]
fn reads_the_profile_table() {
    assert_eq!(parse_table(PROFILE), Ok(Some(table())));
}

#[test]
fn reads_the_table_in_the_fixture_excerpt_and_skips_its_use() {
    // The excerpt has `v.deferredLibraryParts[a]` first, which is a use, not the table.
    let js = fixture_js();
    assert!(js.contains("v.deferredLibraryParts[a]"));
    assert_eq!(parse_table(&js), Ok(Some(table())));
}

#[test]
fn reads_quoted_keys_and_odd_spacing() {
    let js = r#"x={ "deferredLibraryParts" : { "_i7" : [ 0 , 1, ], '_i14':[0] , },
        deferredPartUris :[ 'a.js' , "b\"c.js", ], z:1}"#;
    assert_eq!(
        parse_table(js),
        Ok(Some(Table {
            uris: vec!["a.js".into(), "b\"c.js".into()],
            libs: vec![("_i7".into(), vec![0, 1]), ("_i14".into(), vec![0])],
        }))
    );
}

#[test]
fn an_empty_table_is_a_table_with_no_routes() {
    let js = "deferredLibraryParts:{},deferredPartUris:[],";
    assert_eq!(parse_table(js), Ok(Some(Table::default())));
}

#[test]
fn no_table_means_no_deferred_code() {
    assert_eq!(parse_table("var main=1;"), Ok(None));
    assert_eq!(parse_table("g=v.deferredLibraryParts[a]"), Ok(None));
}

#[test]
fn two_tables_are_unreadable() {
    let js = format!("{MINIFIED}\n{MINIFIED}");
    assert_eq!(parse_table(&js), Err(Unreadable));
}

#[test]
fn a_malformed_or_inconsistent_table_is_unreadable() {
    for js in [
        // no value for a key
        "deferredLibraryParts:{_i7:},deferredPartUris:[\"a\"]",
        // not a list of numbers
        "deferredLibraryParts:{_i7:[a]},deferredPartUris:[\"a\"]",
        // an unterminated body
        "deferredLibraryParts:{_i7:[0],deferredPartUris:[\"a\"]",
        // an unterminated list
        "deferredLibraryParts:{_i7:[0]},deferredPartUris:[\"a\"",
        // a part that is not a string
        "deferredLibraryParts:{_i7:[0]},deferredPartUris:[1]",
        // an index out of range
        "deferredLibraryParts:{_i7:[0,1]},deferredPartUris:[\"a\"]",
        // a key twice
        "deferredLibraryParts:{_i7:[0],_i7:[0]},deferredPartUris:[\"a\"]",
        // only one of the two
        "deferredLibraryParts:{_i7:[0]},",
        "deferredPartUris:[\"a\"],",
    ] {
        assert_eq!(parse_table(js), Err(Unreadable), "{js}");
    }
}

// Which bytes belong to which route.

#[test]
fn attributes_own_and_shared_bytes_per_route() {
    let js = fixture_js();
    let dir = build_dir(&js);
    make_newer(dir.path());
    let (report, warning) = shop_report(dir.path()).unwrap();
    assert_eq!(warning, None);
    assert_eq!(report.main_bytes, js.len() as u64);
    assert_eq!(report.route_count, 6);
    let routes: Vec<_> = report
        .routes
        .iter()
        .map(|r| {
            (
                r.pattern.as_str(),
                r.own,
                r.shared,
                r.total(),
                r.parts.clone(),
            )
        })
        .collect();
    assert_eq!(
        routes,
        [
            (
                "/checkout",
                1090,
                4169,
                5259,
                vec![
                    "main.dart.js_2.part.js".to_string(),
                    "main.dart.js_1.part.js".into()
                ]
            ),
            (
                "/products/:id",
                1813,
                4169,
                5982,
                vec![
                    "main.dart.js_2.part.js".to_string(),
                    "main.dart.js_3.part.js".into()
                ]
            ),
        ]
    );
    let parts: Vec<_> = report
        .parts
        .iter()
        .map(|p| (p.file.as_str(), p.bytes, p.routes.clone()))
        .collect();
    assert_eq!(
        parts,
        [
            (
                "main.dart.js_2.part.js",
                4169,
                vec!["/checkout".to_string(), "/products/:id".into()]
            ),
            (
                "main.dart.js_1.part.js",
                1090,
                vec!["/checkout".to_string()]
            ),
            (
                "main.dart.js_3.part.js",
                1813,
                vec!["/products/:id".to_string()]
            ),
        ]
    );
    assert!(report.over_budget().is_empty());
}

#[test]
fn the_text_report_is_aligned() {
    let js = fixture_js();
    let dir = build_dir(&js);
    make_newer(dir.path());
    let (report, _) = shop_report(dir.path()).unwrap();
    // The excerpt is under 1 KB, which is shown as plain bytes.
    assert!(js.len() < 1024);
    let main = format!("{} B", js.len());
    let text = report.text();
    assert_eq!(text.len(), 4);
    // The columns line up: the sizes start at the same column on every row.
    let at = |line: &str, needle: &str| line.find(needle).unwrap();
    assert_eq!(at(&text[0], &main), at(&text[1], "5259 B (5.1 KB)"));
    assert_eq!(at(&text[1], "5259 B"), at(&text[2], "5982 B"));
    assert!(text[0].starts_with("main.dart.js  "), "{}", text[0]);
    assert!(text[0].ends_with("budget 3.0 MB"), "{}", text[0]);
    assert!(text[1].starts_with("/checkout      CheckoutRoute  checkout/page.dart  "));
    assert!(text[1].contains("5259 B (5.1 KB)"));
    assert!(text[1].contains("own 1090 B, shared 4169 B"));
    assert!(text[1].ends_with("budget 8.0 KB"));
    assert!(text[2].starts_with("/products/:id  ProductRoute   products/$id/page.dart  "));
    assert!(text[2].contains("own 1813 B, shared 4169 B"));
    assert_eq!(
        text[3],
        "shared  main.dart.js_2.part.js  4169 B (4.1 KB): /checkout, /products/:id"
    );
}

#[test]
fn the_json_lines_are_main_routes_then_every_part() {
    let js = fixture_js();
    let dir = build_dir(&js);
    make_newer(dir.path());
    let (report, _) = shop_report(dir.path()).unwrap();
    let lines = report.json_lines();
    assert_eq!(
        lines,
        [
            format!(
                r#"{{"kind":"main","file":"main.dart.js","bytes":{},"budget":3145728}}"#,
                js.len()
            ),
            r#"{"kind":"route","pattern":"/checkout","route":"CheckoutRoute","file":"lib/app/checkout/page.dart","parts":["main.dart.js_2.part.js","main.dart.js_1.part.js"],"own":1090,"shared":4169,"bytes":5259,"budget":8192}"#.into(),
            r#"{"kind":"route","pattern":"/products/:id","route":"ProductRoute","file":"lib/app/products/$id/page.dart","parts":["main.dart.js_2.part.js","main.dart.js_3.part.js"],"own":1813,"shared":4169,"bytes":5982,"budget":8192}"#.into(),
            r#"{"kind":"part","file":"main.dart.js_2.part.js","bytes":4169,"routes":["/checkout","/products/:id"]}"#.into(),
            r#"{"kind":"part","file":"main.dart.js_1.part.js","bytes":1090,"routes":["/checkout"]}"#.into(),
            r#"{"kind":"part","file":"main.dart.js_3.part.js","bytes":1813,"routes":["/products/:id"]}"#.into(),
        ]
    );
}

#[test]
fn a_part_no_route_loads_is_listed_as_other() {
    let js = fixture_js().replace(
        "deferredLibraryParts:{_i7:[0,1],_i14:[0,2]}",
        "deferredLibraryParts:{_i7:[0,1],_i14:[0,2],other:[3]}",
    );
    let js = js.replace(
        "\"main.dart.js_3.part.js\"]",
        "\"main.dart.js_3.part.js\",\"main.dart.js_4.part.js\"]",
    );
    let dir = build_dir(&js);
    fs::write(dir.path().join("main.dart.js_4.part.js"), vec![b'x'; 700]).unwrap();
    make_newer(dir.path());
    let (report, _) = shop_report(dir.path()).unwrap();
    assert_eq!(
        report.text().last().unwrap(),
        "other   main.dart.js_4.part.js  700 B: deferred imports `other`"
    );
    // Its bytes belong to no route.
    assert_eq!(report.routes[0].total(), 5259);
    let last = report.json_lines().pop().unwrap();
    assert_eq!(
        last,
        r#"{"kind":"part","file":"main.dart.js_4.part.js","bytes":700,"routes":[]}"#
    );
}

#[test]
fn a_build_without_deferred_code_is_fine_for_an_app_without_deferred_routes() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("pubspec.yaml"), "name: demo\n").unwrap();
    fs::create_dir_all(dir.path().join("lib/app")).unwrap();
    fs::write(
        dir.path().join("lib/app/page.dart"),
        "class HomePage extends StatelessWidget { const HomePage({super.key}); }",
    )
    .unwrap();
    fs::write(dir.path().join("lib/app.g.dart"), "").unwrap();
    let web = build_dir("var main = 1;");
    make_newer(web.path());
    let cfg = Config::load(dir.path()).unwrap();
    let (_, _, app) = analyze(&dir.path().join("lib/app"), &cfg).unwrap();
    let size = Size {
        build: "build/web".into(),
        main: None,
        route: None,
        routes: vec![],
    };
    // The part files exist but no table names them.
    let (report, warning) = size::report(&app, &cfg, &size, dir.path(), web.path(), "b").unwrap();
    assert_eq!(warning, None);
    assert!(report.routes.is_empty() && report.parts.is_empty());
    assert_eq!(report.text().len(), 1);
}

// The stale-build checks.

#[test]
fn a_build_missing_a_route_is_an_error() {
    let js = fixture_js().replace("_i7:[0,1],", "");
    assert_eq!(
        error_of(&js),
        "build/web/main.dart.js was built from another lib/app.g.dart: it loads deferred code as `_i14`, and the routes now defer `_i7` (checkout/page.dart), `_i14` (products/$id/page.dart); run `flutter build web` again"
    );
}

#[test]
fn a_build_with_an_extra_route_is_an_error() {
    let js = fixture_js().replace("_i14:[0,2]", "_i14:[0,2],_i9:[0]");
    assert_eq!(
        error_of(&js),
        "build/web/main.dart.js was built from another lib/app.g.dart: it loads deferred code as `_i7`, `_i14`, `_i9`, and the routes now defer `_i7` (checkout/page.dart), `_i14` (products/$id/page.dart); run `flutter build web` again"
    );
}

#[test]
fn a_build_with_no_table_where_routes_are_deferred_is_an_error() {
    assert_eq!(
        error_of("var main = 1;"),
        "build/web/main.dart.js was built from another lib/app.g.dart: it loads deferred code as nothing, and the routes now defer `_i7` (checkout/page.dart), `_i14` (products/$id/page.dart); run `flutter build web` again"
    );
}

#[test]
fn an_unreadable_table_is_an_error() {
    assert_eq!(
        error_of("deferredLibraryParts:{_i7:[0,9]},deferredPartUris:[\"a\"]"),
        "build/web/main.dart.js: can't read dart2js's table of deferred parts (`deferredLibraryParts`, `deferredPartUris`); is it the output of `flutter build web`?"
    );
}

#[test]
fn a_missing_part_file_is_an_error() {
    let dir = build_dir(&fixture_js());
    make_newer(dir.path());
    fs::remove_file(dir.path().join("main.dart.js_3.part.js")).unwrap();
    assert_eq!(
        format!("{:#}", shop_report(dir.path()).unwrap_err()),
        "build/web/main.dart.js_3.part.js is missing: the build is incomplete"
    );
}

#[test]
fn a_missing_main_is_an_error() {
    let dir = tempfile::tempdir().unwrap();
    assert_eq!(
        format!("{:#}", shop_report(dir.path()).unwrap_err()),
        "no main.dart.js in build/web: run `flutter build web` first (`fsp size` reads the JavaScript build)"
    );
}

#[test]
fn a_build_older_than_the_generated_file_is_a_warning() {
    let dir = build_dir(&fixture_js());
    set_modified(
        &dir.path().join("main.dart.js"),
        SystemTime::UNIX_EPOCH + Duration::from_hours(24),
    );
    let (report, warning) = shop_report(dir.path()).unwrap();
    // It is only a warning: the report is there.
    assert_eq!(report.routes.len(), 2);
    assert_eq!(
        warning.as_deref(),
        Some(
            "warning: build/web/main.dart.js is older than lib/app.g.dart; if the routes changed since, run `flutter build web` again"
        )
    );
    make_newer(dir.path());
    assert_eq!(shop_report(dir.path()).unwrap().1, None);
}

#[test]
fn a_missing_generated_file_is_an_error() {
    let project = tempfile::tempdir().unwrap();
    fs::write(project.path().join("pubspec.yaml"), "name: demo\n").unwrap();
    fs::create_dir_all(project.path().join("lib/app")).unwrap();
    fs::write(
        project.path().join("lib/app/page.dart"),
        "class HomePage extends StatelessWidget { const HomePage({super.key}); }",
    )
    .unwrap();
    let cfg = Config::load(project.path()).unwrap();
    let (_, _, app) = analyze(&project.path().join("lib/app"), &cfg).unwrap();
    let web = build_dir("var main = 1;");
    let size = Size {
        build: "build/web".into(),
        main: None,
        route: None,
        routes: vec![],
    };
    let err = size::report(&app, &cfg, &size, project.path(), web.path(), "build/web").unwrap_err();
    assert_eq!(
        format!("{err:#}"),
        "lib/app.g.dart not found: run `fsp gen`, then `flutter build web`"
    );
}

// The `size:` section.

fn size_of(lines: &[&str]) -> anyhow::Result<Size> {
    let body: String = lines.iter().map(|l| format!("    {l}\n")).collect();
    let cfg = Pubspec::parse(&format!("name: demo\nfespalier:\n  size:\n{body}"))?.config;
    cfg.size.expect("a size section").validate()
}

fn bytes_of(value: &str) -> anyhow::Result<u64> {
    size_of(&[&format!("main: {value}")]).map(|s| s.main.unwrap())
}

#[test]
fn sizes_take_units_and_plain_bytes() {
    for (value, bytes) in [
        ("3 MB", 3 * 1_048_576),
        ("1.5 MB", 1_572_864),
        ("64 KB", 65_536),
        ("64KB", 65_536),
        ("900 B", 900),
        ("0.5 KB", 512),
        ("4096", 4096),
        ("\"4 KB\"", 4096),
    ] {
        assert_eq!(bytes_of(value).unwrap(), bytes, "{value}");
    }
}

#[test]
fn a_size_that_is_not_one_names_the_key() {
    for (value, shown) in [
        ("3 mb", "3 mb"),
        ("-1", "-1"),
        ("0", "0"),
        ("3 GB", "3 GB"),
        ("x", "x"),
        ("\"3  MB\"", "3  MB"),
        ("\".5 KB\"", ".5 KB"),
        ("1.5", "1.5"),
        ("[1, 2]", "[1,2]"),
    ] {
        assert_eq!(
            format!("{:#}", bytes_of(value).unwrap_err()),
            format!(
                "`fespalier.size.main` must be a size like `3 MB`, `64 KB` or `900 B` (KB is 1,024 bytes), or a number of bytes, got `{shown}`"
            ),
            "{value}"
        );
    }
    assert_eq!(
        format!("{:#}", size_of(&["route: nope"]).unwrap_err()),
        "`fespalier.size.route` must be a size like `3 MB`, `64 KB` or `900 B` (KB is 1,024 bytes), or a number of bytes, got `nope`"
    );
    assert_eq!(
        format!(
            "{:#}",
            size_of(&["routes:", "  /checkout: lots"]).unwrap_err()
        ),
        "`fespalier.size.routes./checkout` must be a size like `3 MB`, `64 KB` or `900 B` (KB is 1,024 bytes), or a number of bytes, got `lots`"
    );
}

#[test]
fn the_build_folder_defaults_and_stays_in_the_project() {
    assert_eq!(size_of(&["main: 1 MB"]).unwrap().build, "build/web");
    assert_eq!(size_of(&["build: out/./web/"]).unwrap().build, "out/web");
    assert_eq!(
        format!("{:#}", size_of(&["build: ../web"]).unwrap_err()),
        "`fespalier.size.build` must be a folder inside the project (relative, no `..`), got `../web`"
    );
}

#[test]
fn a_misspelled_key_names_the_ones_there_are() {
    let err = Pubspec::parse("name: demo\nfespalier:\n  size:\n    mian: 3 MB\n").unwrap_err();
    assert_eq!(
        format!("{err:#}"),
        "invalid pubspec.yaml: fespalier.size: unknown field `mian`, expected one of `build`, `main`, `route`, `routes` at line 4 column 5"
    );
}

#[test]
fn the_route_budget_applies_to_every_route_and_a_pattern_wins() {
    let dir = build_dir(&fixture_js());
    make_newer(dir.path());
    let (cfg, _) = shop_size();
    let (_, _, app) = analyze(&shop().join(&cfg.app_dir), &cfg).unwrap();
    let size = size_of(&["route: 6 KB", "routes:", "  /checkout: 5000"]).unwrap();
    let (report, _) = size::report(&app, &cfg, &size, &shop(), dir.path(), "b").unwrap();
    let budgets: Vec<_> = report.routes.iter().map(|r| r.budget).collect();
    assert_eq!(budgets, [Some(5000), Some(6144)]);
    // /checkout is 5259 B, over 5000; /products/:id is 5982 B, within 6144.
    assert_eq!(report.over_budget(), ["/checkout"]);
    assert!(
        report.text()[1].ends_with("OVER budget 4.9 KB by 259 B"),
        "{:?}",
        report.text()
    );
    assert!(report.text()[2].ends_with("budget 6.0 KB"));
}

#[test]
fn main_over_budget_comes_first() {
    let dir = build_dir(&fixture_js());
    make_newer(dir.path());
    let (cfg, _) = shop_size();
    let (_, _, app) = analyze(&shop().join(&cfg.app_dir), &cfg).unwrap();
    let size = size_of(&["main: 100 B", "routes:", "  /products/:id: 1 KB"]).unwrap();
    let (report, _) = size::report(&app, &cfg, &size, &shop(), dir.path(), "b").unwrap();
    assert_eq!(report.over_budget(), ["main.dart.js", "/products/:id"]);
}

#[test]
fn a_budget_for_something_that_is_not_a_deferred_route_is_an_error() {
    let dir = build_dir(&fixture_js());
    make_newer(dir.path());
    let (cfg, _) = shop_size();
    let (_, _, app) = analyze(&shop().join(&cfg.app_dir), &cfg).unwrap();
    let report_with = |lines: &[&str]| {
        let size = size_of(lines).unwrap();
        format!(
            "{:#}",
            size::report(&app, &cfg, &size, &shop(), dir.path(), "b").unwrap_err()
        )
    };
    assert_eq!(
        report_with(&["routes:", "  /nowhere: 1 KB"]),
        "`fespalier.size.routes`: `/nowhere` is not a route; write the pattern as `fsp routes` prints it (`/products/:id`)"
    );
    assert_eq!(
        report_with(&["routes:", "  /cart: 1 KB"]),
        "`fespalier.size.routes`: `/cart` is not deferred, so its code is in main.dart.js; budget that with `main`"
    );
}

// The load id is the import prefix of the generated file.

#[test]
fn the_prefix_is_the_one_the_generated_import_has() {
    let page = |name: &str| {
        format!("class {name}Page extends StatelessWidget {{ const {name}Page({{super.key}}); }}")
    };
    let dir = tempfile::tempdir().unwrap();
    fs::write(
        dir.path().join("pubspec.yaml"),
        "name: demo\nfespalier:\n  deferred: true\n",
    )
    .unwrap();
    for (rel, name) in [
        ("page.dart", "Home"),
        ("about/page.dart", "About"),
        ("shop/page.dart", "Shop"),
        ("shop/$id/page.dart", "Item"),
        ("zed/page.dart", "Zed"),
    ] {
        let body = match (rel, name) {
            ("shop/$id/page.dart", _) => "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.id}); final int id; }".to_string(),
            _ => page(name),
        };
        let p = dir.path().join("lib/app").join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, body).unwrap();
    }
    let cfg = Config::load(dir.path()).unwrap();
    let (code, diags, _) = build(&dir.path().join("lib/app"), &cfg).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    let (_, _, app) = analyze(&dir.path().join("lib/app"), &cfg).unwrap();
    let deferred = size::deferred_routes(&app);
    assert_eq!(deferred.len(), 5);
    for (prefix, route) in &deferred {
        let file = crate::emit::rel(route, crate::scan::Kind::Page).replace('$', "\\$");
        assert!(
            code.contains(&format!("import 'app/{file}' deferred as {prefix};")),
            "no `deferred as {prefix}` for {file} in:\n{code}"
        );
    }
}
