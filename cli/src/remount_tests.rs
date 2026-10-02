//! `remount`: when a page gets a fresh state because its URL changed. A `route.dart` with
//! `const remount = Remount.onSegments;` applies to its folder and everything below it, the
//! nearest one wins over the pubspec's `remount:`, and the generated page is keyed by it.

use std::fs;

use crate::config::{Config, Pubspec, Remount};
use crate::{analyze, build, routes};

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

fn diags_with(cfg: &Config, files: &[(&str, &str)]) -> Vec<String> {
    let dir = project(files);
    let (_, diags, _) = build(&dir.path().join("lib/app"), cfg).unwrap();
    diags
        .0
        .iter()
        .map(std::string::ToString::to_string)
        .collect()
}

fn errors(files: &[(&str, &str)]) -> Vec<String> {
    diags_with(&Config::default(), files)
        .into_iter()
        .filter(|d| d.starts_with('✗'))
        .collect()
}

fn code_with(cfg: &Config, files: &[(&str, &str)]) -> String {
    let dir = project(files);
    let (code, diags, _) = build(&dir.path().join("lib/app"), cfg).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    code
}

fn code(files: &[(&str, &str)]) -> String {
    code_with(&Config::default(), files)
}

fn with_default(remount: Remount) -> Config {
    Config {
        remount,
        ..Config::default()
    }
}

/// The remount of each route, in the order of the route table, by its pattern.
fn remounts(cfg: &Config, files: &[(&str, &str)]) -> Vec<(String, Remount)> {
    let dir = project(files);
    let (_, diags, app) = analyze(&dir.path().join("lib/app"), cfg).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    app.routes
        .iter()
        .filter(|r| r.is_route())
        .map(|r| (r.dir.clone(), r.remount))
        .collect()
}

/// The code with every run of whitespace a single space, so indentation doesn't matter.
fn flat(code: &str) -> String {
    code.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn has(code: &str, needles: &[&str]) {
    let flat_code = flat(code);
    for n in needles {
        assert!(flat_code.contains(&flat(n)), "missing `{n}` in:\n{code}");
    }
}

fn page(name: &str) -> String {
    format!("class {name}Page extends StatelessWidget {{ const {name}Page({{super.key}}); }}")
}

fn item() -> String {
    "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.id}); final int id; }".into()
}

const SEGMENTS: &str = "const remount = Remount.onSegments;\n";
const LOCATION: &str = "const remount = Remount.onLocation;\n";
const NEVER: &str = "const remount = Remount.never;\n";
const FADE: &str =
    "Page<void> transition(LocalKey key, Widget child) => Transitions.fade(key, child);";
const SHEET: &str =
    "Page<void> present(LocalKey key, Widget child) => SheetPage(key: key, child: child);";

fn config(yaml: &str) -> anyhow::Result<Config> {
    Ok(Pubspec::parse(yaml)?.config)
}

// ---- the config ----

#[test]
fn the_default_is_never() {
    assert_eq!(Config::default().remount, Remount::Never);
    assert_eq!(config("name: demo\n").unwrap().remount, Remount::Never);
    assert_eq!(
        config("fespalier:\n  format: true\n").unwrap().remount,
        Remount::Never
    );
}

#[test]
fn the_pubspec_names_each_value_in_snake_case() {
    for (value, want) in [
        ("never", Remount::Never),
        ("on_segments", Remount::OnSegments),
        ("on_location", Remount::OnLocation),
    ] {
        let c = config(&format!("fespalier:\n  remount: {value}\n")).unwrap();
        assert_eq!(c.remount, want, "{value}");
        assert_eq!(want.config_name(), value);
    }
}

#[test]
fn the_pubspec_rejects_what_is_not_a_value() {
    for bad in ["onSegments", "always", "true", "''"] {
        let e = format!(
            "{:#}",
            config(&format!("fespalier:\n  remount: {bad}\n")).unwrap_err()
        );
        assert!(
            e.contains("remount")
                || (e.contains("unknown variant")
                    && e.contains("never")
                    && e.contains("on_segments")
                    && e.contains("on_location")),
            "{bad}: {e}"
        );
        assert!(e.contains("on_segments"), "{bad}: {e}");
    }
}

// ---- what a route.dart says, and who inherits it ----

#[test]
fn without_one_the_pubspec_decides() {
    let files = [("page.dart", page("Home")), ("items/$id/page.dart", item())];
    let files: Vec<(&str, &str)> = files.iter().map(|(p, b)| (*p, b.as_str())).collect();
    for want in [Remount::Never, Remount::OnSegments, Remount::OnLocation] {
        let all = remounts(&with_default(want), &files);
        assert!(all.iter().all(|(_, r)| *r == want), "{want:?}: {all:?}");
    }
}

#[test]
fn a_route_dart_covers_its_folder_and_everything_below_and_no_sibling() {
    let pg1 = page("P1");
    let pg2 = page("P2");
    let pg3 = page("P3");
    let item = item();
    let files = [
        ("page.dart", pg1.as_str()),
        ("route.dart", "// nothing here\nconst linkable = true;"),
        ("shop/route.dart", SEGMENTS),
        ("shop/page.dart", pg2.as_str()),
        ("shop/items/$id/page.dart", item.as_str()),
        ("blog/page.dart", pg3.as_str()),
    ];
    let all = remounts(&Config::default(), &files);
    let of = |dir: &str| all.iter().find(|(d, _)| d == dir).unwrap().1;
    assert_eq!(of(""), Remount::Never);
    assert_eq!(of("shop"), Remount::OnSegments);
    assert_eq!(of("shop/items/$id"), Remount::OnSegments);
    assert_eq!(of("blog"), Remount::Never);
}

#[test]
fn the_nearest_route_dart_wins_over_the_ones_above_and_the_pubspec() {
    let pg1 = page("P1");
    let pg2 = page("P2");
    let pg3 = page("P3");
    let pg4 = page("P4");
    let pg5 = page("P5");
    let files = [
        ("route.dart", LOCATION),
        ("page.dart", pg1.as_str()),
        ("admin/route.dart", NEVER),
        ("admin/page.dart", pg2.as_str()),
        ("admin/tools/page.dart", pg3.as_str()),
        ("admin/tools/deep/route.dart", SEGMENTS),
        ("admin/tools/deep/page.dart", pg4.as_str()),
        ("blog/page.dart", pg5.as_str()),
    ];
    let all = remounts(&with_default(Remount::OnSegments), &files);
    let of = |dir: &str| all.iter().find(|(d, _)| d == dir).unwrap().1;
    assert_eq!(of(""), Remount::OnLocation);
    assert_eq!(of("admin"), Remount::Never);
    assert_eq!(of("admin/tools"), Remount::Never);
    assert_eq!(of("admin/tools/deep"), Remount::OnSegments);
    assert_eq!(of("blog"), Remount::OnLocation);
}

#[test]
fn a_group_and_a_folder_without_a_page_pass_it_on() {
    let pg1 = page("P1");
    let pg2 = page("P2");
    let pg3 = page("P3");
    let files = [
        ("(shop)/route.dart", LOCATION),
        ("(shop)/cart/page.dart", pg1.as_str()),
        ("docs/route.dart", SEGMENTS),
        ("docs/guide/page.dart", pg2.as_str()),
        ("other/page.dart", pg3.as_str()),
    ];
    let all = remounts(&Config::default(), &files);
    let of = |dir: &str| all.iter().find(|(d, _)| d == dir).unwrap().1;
    assert_eq!(of("(shop)/cart"), Remount::OnLocation);
    assert_eq!(of("docs/guide"), Remount::OnSegments);
    assert_eq!(of("other"), Remount::Never);
}

#[test]
fn a_route_dart_may_hold_remount_beside_the_others_and_an_import() {
    let pg1 = page("P1");
    let files = [
        (
            "shop/route.dart",
            "import 'package:fespalier/fespalier.dart';\n\nconst caseSensitive = false;\nconst linkable = false;\nconst remount = Remount.onSegments;\n",
        ),
        ("shop/page.dart", pg1.as_str()),
    ];
    let all = remounts(&Config::default(), &files);
    assert_eq!(all, [("shop".to_string(), Remount::OnSegments)]);
}

#[test]
fn an_import_prefix_is_fine() {
    let pg1 = page("P1");
    let files = [
        (
            "shop/route.dart",
            "import 'package:fespalier/fespalier.dart' as fsp;\nconst remount = fsp.Remount.onLocation;\n",
        ),
        ("shop/page.dart", pg1.as_str()),
    ];
    let all = remounts(&Config::default(), &files);
    assert_eq!(all, [("shop".to_string(), Remount::OnLocation)]);
}

#[test]
fn whitespace_in_the_value_does_not_matter() {
    let pg1 = page("P1");
    let files = [
        (
            "shop/route.dart",
            "const remount =\n    Remount . onSegments ;\n",
        ),
        ("shop/page.dart", pg1.as_str()),
    ];
    let all = remounts(&Config::default(), &files);
    assert_eq!(all, [("shop".to_string(), Remount::OnSegments)]);
}

// ---- diagnostics ----

#[test]
fn declaring_it_twice_is_an_error_at_the_second() {
    let e = errors(&[
        (
            "shop/route.dart",
            "const remount = Remount.never;\nconst remount = Remount.onSegments;",
        ),
        ("shop/page.dart", &page("Shop")),
    ]);
    assert_eq!(e, ["✗ shop/route.dart:2  `remount` is declared twice"]);
}

#[test]
fn it_must_be_one_of_the_three_values_written_out() {
    let msg = "`remount` must be `Remount.never`, `Remount.onSegments` or `Remount.onLocation`, written out: fsp reads it from the source, it doesn't run it";
    for body in [
        "const remount = Remount.sometimes;",
        "const remount = Remount.on_segments;",
        "const remount = onSegments;",
        "const remount = 'onSegments';",
        "const remount = true;",
        "const remount = Other.onSegments;",
        "const remount = a.b.Remount.never;",
        "const remount = Remount.onSegments.index;",
        "const remount = mode;",
    ] {
        let e = errors(&[("route.dart", body), ("page.dart", &page("Home"))]);
        assert_eq!(e, [format!("✗ route.dart:1  {msg}")], "{body}");
    }
}

#[test]
fn it_must_be_const() {
    for kw in ["final", "var", "late final", "Remount"] {
        let e = errors(&[
            ("route.dart", &format!("{kw} remount = Remount.onSegments;")),
            ("page.dart", &page("Home")),
        ]);
        assert_eq!(
            e,
            [
                "✗ route.dart:1  `remount` must be `const`: write `const remount = Remount.onSegments;`"
            ],
            "{kw}"
        );
    }
    // A getter is not a constant either: the generator can't read its value.
    let e = errors(&[
        ("route.dart", "Remount get remount => Remount.onSegments;"),
        ("page.dart", &page("Home")),
    ]);
    assert_eq!(e.len(), 1, "{e:?}");
}

#[test]
fn a_bad_route_dart_leaves_the_setting_it_would_have_overridden() {
    // The error stops the generator anyway; what is left is the inherited value, not a guess.
    let dir = project(&[
        ("shop/route.dart", "const remount = maybe;"),
        ("shop/page.dart", &page("Shop")),
    ]);
    let (_, diags, app) = analyze(
        &dir.path().join("lib/app"),
        &with_default(Remount::OnLocation),
    )
    .unwrap();
    assert!(diags.has_errors());
    let shop = app.routes.iter().find(|r| r.dir == "shop").unwrap();
    assert_eq!(shop.remount, Remount::OnLocation);
}

#[test]
fn a_route_dart_with_only_remount_is_not_empty() {
    let e = errors(&[("route.dart", SEGMENTS), ("page.dart", &page("Home"))]);
    assert!(e.is_empty(), "{e:?}");
}

#[test]
fn a_transition_that_does_not_take_the_key_is_warned_about() {
    let no_key = "Page<void> transition(Widget child) => MaterialPage<void>(child: child);";
    let d = diags_with(
        &Config::default(),
        &[
            ("transition.dart", no_key),
            ("route.dart", SEGMENTS),
            ("page.dart", &page("Home")),
            ("items/$id/page.dart", &item()),
        ],
    );
    assert_eq!(
        d,
        [
            "! items/$id/page.dart:1  `remount` has no effect here: the `transition()` that builds this page doesn't take its key; add a `LocalKey key` parameter and give it to the page"
        ],
        "{d:?}"
    );
    // One that takes it, and a route it has nothing to watch in, are fine.
    let d = diags_with(
        &Config::default(),
        &[
            ("transition.dart", FADE),
            ("route.dart", SEGMENTS),
            ("page.dart", &page("Home")),
            ("items/$id/page.dart", &item()),
        ],
    );
    assert!(d.is_empty(), "{d:?}");
    let d = diags_with(
        &Config::default(),
        &[
            ("transition.dart", no_key),
            ("route.dart", SEGMENTS),
            ("page.dart", &page("Home")),
        ],
    );
    assert!(d.is_empty(), "{d:?}");
}

// ---- what is generated ----

#[test]
fn never_is_the_code_there_was_before() {
    let files = [
        ("page.dart", page("Home")),
        ("items/$id/page.dart", item()),
        ("items/$id/edit/page.dart", page("Edit")),
    ];
    let files: Vec<(&str, &str)> = files.iter().map(|(p, b)| (*p, b.as_str())).collect();
    let plain = code(&files);
    assert!(!plain.contains("remount"), "{plain}");
    assert!(!plain.contains("Remount"), "{plain}");
    has(&plain, &["builder: (context, state) =>"]);
    // Said outright, in the pubspec or a route.dart, it is the same file.
    assert_eq!(code_with(&with_default(Remount::Never), &files), plain);
    let mut with_file = files.clone();
    with_file.push(("route.dart", NEVER));
    assert_eq!(code(&with_file), plain);
    // And so is a folder that opts in with nothing to watch: no segment, `onSegments` is `never`.
    let mut only_static = vec![("page.dart", files[0].1), ("route.dart", SEGMENTS)];
    only_static.push(("about/page.dart", files[2].1));
    let a = code(&only_static);
    assert!(!a.contains("emount"), "{a}");
}

#[test]
fn a_page_without_a_transition_is_keyed_by_its_segments() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("items/route.dart", SEGMENTS),
        ("items/$id/page.dart", &item()),
    ]);
    has(
        &c,
        &[
            "pageBuilder: (context, state) => remountPage(\n          context,\n          state,\n          remountKey(state, Remount.onSegments, const ['id']),\n",
        ],
    );
    // The home page, outside the folder, is as before.
    has(&c, &["builder: (context, state) => const _i0.HomePage(),"]);
    assert_eq!(c.matches("remountPage(").count(), 1, "{c}");
}

#[test]
fn every_segment_in_the_path_is_in_the_key_in_path_order() {
    let two = "class TwoPage extends StatelessWidget { const TwoPage({super.key, required this.a, required this.b}); final int a; final String b; }";
    let c = code(&[
        ("route.dart", SEGMENTS),
        ("a/$a/b/$b/page.dart", two),
        ("a/$a/page.dart", &item().replace("id", "a")),
    ]);
    has(
        &c,
        &[
            "remountKey(state, Remount.onSegments, const ['a', 'b'])",
            "remountKey(state, Remount.onSegments, const ['a'])",
        ],
    );
}

#[test]
fn a_catch_all_is_a_segment_too() {
    let rest = "class FilesPage extends StatelessWidget { const FilesPage({super.key, required this.path}); final List<String> path; }";
    let c = code(&[("route.dart", SEGMENTS), ("files/$$$path/page.dart", rest)]);
    has(
        &c,
        &["remountKey(state, Remount.onSegments, const ['path'])"],
    );
}

#[test]
fn on_location_keys_a_page_with_no_segment_too() {
    let c = code(&[
        ("route.dart", LOCATION),
        ("page.dart", &page("Home")),
        ("items/$id/page.dart", &item()),
    ]);
    assert_eq!(
        c.matches("remountKey(state, Remount.onLocation)").count(),
        2,
        "{c}"
    );
    assert!(!c.contains("  builder: (context, state) =>"), "{c}");
}

#[test]
fn the_pubspec_default_keys_every_page() {
    let c = code_with(
        &with_default(Remount::OnLocation),
        &[
            ("page.dart", &page("Home")),
            ("about/page.dart", &page("A")),
        ],
    );
    assert_eq!(c.matches("remountPage(").count(), 2, "{c}");
}

#[test]
fn a_transition_gets_the_key_where_it_takes_the_page_key() {
    let c = code(&[
        ("transition.dart", FADE),
        ("items/route.dart", SEGMENTS),
        ("items/$id/page.dart", &item()),
        ("about/page.dart", &page("About")),
    ]);
    has(
        &c,
        &[
            ".transition( remountKey(state, Remount.onSegments, const ['id']), buildWithParams(",
            // The route outside the folder keeps go_router's key.
            ".transition( state.pageKey, const _i1.AboutPage(),",
        ],
    );
    // The transition builds the page; there is no `remountPage`.
    assert!(!c.contains("remountPage("), "{c}");
}

#[test]
fn a_transition_with_the_key_after_the_child_or_named_is_keyed_too() {
    let named = "Page<void> transition(Widget child, LocalKey key, GoRouterState state) => Transitions.fade(key, child);";
    let c = code(&[
        ("transition.dart", named),
        ("route.dart", LOCATION),
        ("page.dart", &page("Home")),
    ]);
    has(&c, &["remountKey(state, Remount.onLocation), state,"]);
}

#[test]
fn a_present_page_is_keyed_like_a_transition() {
    let c = code(&[
        ("transition.dart", FADE),
        ("route.dart", SEGMENTS),
        ("buy/$id/page.dart", &item()),
        ("buy/$id/present.dart", SHEET),
    ]);
    has(
        &c,
        &["_i2.present(\n              remountKey(state, Remount.onSegments, const ['id']),"],
    );
}

#[test]
fn a_layout_is_not_remounted() {
    // `/teams/1` to `/teams/2` keeps the layout's state, as it always did: its page is keyed
    // by its folder. The pages inside are what remounts.
    let layout = "class TeamLayout extends StatelessWidget { const TeamLayout({super.key, required this.child}); final Widget child; }";
    let c = code(&[
        ("route.dart", LOCATION),
        ("teams/$id/layout.dart", layout),
        ("teams/$id/page.dart", &item()),
    ]);
    has(&c, &["layoutPage(\n"]);
    assert_eq!(c.matches("remountPage(").count(), 1, "{c}");
    let shell = &c[c.find("ShellRoute(").unwrap()..];
    let shell = &shell[..shell.find("routes: [").unwrap()];
    assert!(!shell.contains("remount"), "{shell}");
    // With a transition, the shell's key is still the layout's folder.
    let c = code(&[
        ("transition.dart", FADE),
        ("route.dart", LOCATION),
        ("teams/$id/layout.dart", layout),
        ("teams/$id/page.dart", &item()),
    ]);
    has(&c, &["const ValueKey<String>('layout:teams/\\$id/')"]);
    assert_eq!(c.matches("remountKey(").count(), 1, "{c}");
}

#[test]
fn a_tab_layouts_own_page_remounts_like_any_page() {
    let layout = "class TabsLayout extends StatelessWidget { const TabsLayout({super.key, required this.shell}); final StatefulNavigationShell shell; }";
    let c = code(&[
        ("(tabs)/layout.dart", layout),
        ("(tabs)/tabs.dart", "const tabs = ['a'];"),
        ("(tabs)/a/route.dart", LOCATION),
        ("(tabs)/a/page.dart", &page("A")),
    ]);
    has(&c, &["remountKey(state, Remount.onLocation)"]);
}

// ---- fsp routes --json ----

#[test]
fn the_json_row_says_it_only_for_a_route_that_remounts() {
    let dir = project(&[
        ("page.dart", &page("Home")),
        ("items/route.dart", SEGMENTS),
        ("items/$id/page.dart", &item()),
        ("live/route.dart", LOCATION),
        ("live/page.dart", &page("Live")),
    ]);
    let (_, _, app) = analyze(&dir.path().join("lib/app"), &Config::default()).unwrap();
    let rows: Vec<serde_json::Value> = routes::json_lines(&app, "lib/app")
        .iter()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    let by = |pattern: &str| rows.iter().find(|r| r["pattern"] == pattern).unwrap();
    assert_eq!(by("/")["remount"], serde_json::Value::Null);
    assert!(by("/").get("remount").is_none());
    assert_eq!(by("/items/:id")["remount"], "on_segments");
    // The tag is where it acts: the home page and a route with nothing to watch have none.
    let tags = |pattern: &str| by(pattern)["tags"].to_string();
    assert_eq!(tags("/"), "[]");
    assert_eq!(tags("/items/:id"), "[\"remount\"]");
    assert_eq!(tags("/live"), "[\"remount\"]");
    assert_eq!(by("/live")["remount"], "on_location");
}

#[test]
fn the_json_row_takes_the_pubspecs_default() {
    let dir = project(&[
        ("page.dart", &page("Home")),
        ("keep/route.dart", NEVER),
        ("keep/page.dart", &page("Keep")),
    ]);
    let (_, _, app) = analyze(
        &dir.path().join("lib/app"),
        &with_default(Remount::OnSegments),
    )
    .unwrap();
    let rows: Vec<serde_json::Value> = routes::json_lines(&app, "lib/app")
        .iter()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    let by = |pattern: &str| rows.iter().find(|r| r["pattern"] == pattern).unwrap();
    assert_eq!(by("/")["remount"], "on_segments");
    assert!(by("/keep").get("remount").is_none());
}
