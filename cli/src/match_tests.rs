//! `AppRoutes.match` / `dataAt`, a section's typed handle and query keys, `meta_unique`,
//! `not_found.dart` taking segments, and `fsp new --not-found`. (The rest of the generator's
//! tests are in `tests.rs`.)

use std::fs;

use crate::config::{Config, Pubspec};
use crate::scaffold::{self, NewArgs};
use crate::{analyze, manifest};

const HOME: &str = "class HomePage extends StatelessWidget { const HomePage({super.key}); }";

fn widget(class: &str, fields: &str, params: &str) -> String {
    format!(
        "class {class} extends StatelessWidget {{ const {class}({{super.key{params}}}); {fields} }}"
    )
}

fn page(name: &str) -> String {
    widget(&format!("{name}Page"), "", "")
}

const LAYOUT: &str = "class SLayout extends StatelessWidget { const SLayout({super.key, required this.child}); final Widget child; }";

fn project(yaml: &str, files: &[(&str, &str)]) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    fs::write(
        dir.path().join("pubspec.yaml"),
        format!("name: demo\n{yaml}"),
    )
    .unwrap();
    for (rel, body) in files {
        let p = dir.path().join("lib/app").join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, body).unwrap();
    }
    dir
}

/// Diagnostics as `✗ file:line  message` (or `!` for a warning).
fn diags(yaml: &str, files: &[(&str, &str)]) -> Vec<String> {
    let dir = project(yaml, files);
    let cfg = Config::load(dir.path()).unwrap();
    let (_, diags, _) = analyze(&dir.path().join("lib/app"), &cfg).unwrap();
    diags
        .0
        .iter()
        .map(std::string::ToString::to_string)
        .collect()
}

fn errors(yaml: &str, files: &[(&str, &str)]) -> Vec<String> {
    diags(yaml, files)
        .into_iter()
        .filter(|d| d.starts_with('✗'))
        .collect()
}

/// The generated files of a project that checks cleanly: (`output`, manifest library).
fn generated(yaml: &str, files: &[(&str, &str)]) -> (String, Option<String>) {
    let dir = project(yaml, files);
    let cfg = Config::load(dir.path()).unwrap();
    let (code, diags, app) = analyze(&dir.path().join("lib/app"), &cfg).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    (code, manifest::emit(&app, &cfg))
}

fn code(files: &[(&str, &str)]) -> String {
    generated("", files).0
}

fn has(code: &str, needles: &[&str]) {
    for n in needles {
        assert!(code.contains(n), "missing `{n}` in:\n{code}");
    }
}

fn lacks(code: &str, needles: &[&str]) {
    for n in needles {
        assert!(!code.contains(n), "unexpected `{n}` in:\n{code}");
    }
}

// --- match and dataAt ------------------------------------------------------------------

#[test]
fn every_route_gets_a_matcher_most_specific_first() {
    let c = code(&[
        ("page.dart", HOME),
        (
            "$id/page.dart",
            &widget("ItemPage", "final int id;", ", required this.id"),
        ),
        ("about/page.dart", &page("About")),
        (
            "docs/$$rest/page.dart",
            &widget(
                "DocsPage",
                "final List<String> rest;",
                ", required this.rest",
            ),
        ),
        (
            "files/$$$path/page.dart",
            &widget(
                "FilesPage",
                "final List<String> path;",
                ", required this.path",
            ),
        ),
        ("docs/new/page.dart", &page("NewDoc")),
    ]);
    let at = |needle: &str| {
        c.find(needle)
            .unwrap_or_else(|| panic!("missing `{needle}` in:\n{c}"))
    };
    // Static parts before `:params` before catch-alls, wherever the folders are.
    assert!(
        at("RouteMatcher(['about']") < at("RouteMatcher([':id']"),
        "{c}"
    );
    assert!(
        at("RouteMatcher(['docs', 'new']") < at("RouteMatcher(['docs', '*rest']"),
        "{c}"
    );
    // The route is built from the params the route itself parses.
    has(
        &c,
        &[
            "static UrlMatch? matchUrl(Uri uri) => matchRoutes(uri, base, _matchers);",
            "static List<ProviderListenable<AsyncValue<Object?>>>? dataAt(Uri uri) => matchUrl(uri)?.data;",
            "RouteMatcher([], (s) => UrlMatch(s.uri, const HomeRoute(), const {}, const [])),",
            "final p = _params",
            "ItemRoute(id: p.id), {'id': p.id}, const [])",
            "DocsRoute(rest: p.rest), {'rest': p.rest}, const [])",
            "static RouteMatch? match(Uri uri) => AppManifest.match(uri);",
            "static RouteMatch? match(Uri uri) {\n    final m = AppRoutes.matchUrl(uri);\n    return m == null ? null : RouteMatch(byType[m.type]!, m);\n  }",
        ],
    );
}

#[test]
fn a_matcher_lists_the_data_the_route_watches() {
    let c = code(&[
        (
            "$id/data.dart",
            "Future<String> data(Ref ref, {required int id, String? q}) async => '';",
        ),
        (
            "$id/page.dart",
            &widget("ItemPage", "final String s;", ", required this.s"),
        ),
        (
            "tags/data.dart",
            "Future<int> data(Ref ref, {List<String> tags = const []}) async => 1;",
        ),
        (
            "tags/page.dart",
            &widget("TagsPage", "final int n;", ", required this.n"),
        ),
        ("plain/page.dart", &page("Plain")),
    ]);
    has(
        &c,
        &[
            // The same expression the page's DataView watches, with the key built from `p`.
            "ItemRoute(id: p.id, q: p.q), {'id': p.id, 'q': p.q}, [_data1((id: p.id, q: p.q))])",
            "watch: (ref) => ref.watch(_data1((id: v.id, q: v.q))),",
            // A list is the QueryList the provider is keyed by, as in the page.
            "[_data3(QueryList(p.tags))])",
            // No data: an empty list, which is not null.
            "RouteMatcher(['plain'], (s) => UrlMatch(s.uri, const PlainRoute(), const {}, const [])),",
        ],
    );
}

#[test]
fn data_that_selects_a_provider_and_provider_files_are_listed_as_they_are() {
    let c = code(&[
        (
            "products/$productId/data.dart",
            "ProviderListenable<AsyncValue<ProductView>> data({required String productId}) => productProvider(productId);",
        ),
        (
            "products/$productId/page.dart",
            "class ProductPage extends StatelessWidget { const ProductPage({super.key, required this.product}); final ProductView product; }",
        ),
        (
            "counter/data.dart",
            "final data = FutureProvider<int>((ref) async => 1);",
        ),
        (
            "counter/page.dart",
            &widget("CounterPage", "final int n;", ", required this.n"),
        ),
    ]);
    // The selector's closure (which returns the app's own provider) and the provider a file exports.
    has(
        &c,
        &[
            "[_data3(p.productId)])",
            "const CounterRoute(), const {}, [_i0.data])",
        ],
    );
}

#[test]
fn section_data_comes_before_the_routes_own_and_needs_no_layout_parse() {
    let c = code(&[
        (
            "teams/$teamId/data.dart",
            "Future<Team> data(Ref ref, {required String teamId}) async => Team();",
        ),
        (
            "teams/$teamId/layout.dart",
            &widget(
                "TeamLayout",
                "final Widget child; final Team team;",
                ", required this.child, required this.team",
            ),
        ),
        ("teams/$teamId/settings/page.dart", &page("Settings")),
        (
            "teams/$teamId/members/$member/data.dart",
            "Future<String> data(Ref ref, {required int member}) async => '';",
        ),
        (
            "teams/$teamId/members/$member/page.dart",
            &widget("MemberPage", "final String s;", ", required this.s"),
        ),
    ]);
    has(
        &c,
        &[
            // A page with no data.dart of its own still has its section's.
            "RouteMatcher(['teams', ':teamId', 'settings'], (s) {",
            "SettingsRoute(teamId: p.teamId)",
            "[_data2(p.teamId)])",
            // Outermost first, then its own.
            "[_data2(p.teamId), _data4(p.member)])",
        ],
    );
}

#[test]
fn matchers_follow_the_case_sensitivity_config() {
    let files = [("page.dart", HOME)];
    let (c, _) = generated("", &files);
    has(&c, &["matchRoutes(uri, base, _matchers);"]);
    let (c, _) = generated("fespalier:\n  case_sensitive: false\n", &files);
    has(
        &c,
        &["matchRoutes(uri, base, _matchers, caseSensitive: false);"],
    );
}

#[test]
fn each_matcher_carries_its_own_case_flag() {
    // The pubspec says any case; a route.dart makes one folder exact.
    let files = [
        ("page.dart", HOME),
        ("exact/route.dart", "const caseSensitive = true;"),
        ("exact/page.dart", &page("Exact")),
        ("exact/deep/page.dart", &page("Deep")),
        ("loose/page.dart", &page("Loose")),
    ];
    let (c, _) = generated("fespalier:\n  case_sensitive: false\n", &files);
    has(
        &c,
        &[
            "RouteMatcher(['exact'], (s) => UrlMatch(s.uri, const ExactRoute(), const {}, const [])),",
            "RouteMatcher(['exact', 'deep'], (s) => UrlMatch(s.uri, const DeepRoute(), const {}, const [])),",
            "RouteMatcher(['loose'], (s) => UrlMatch(s.uri, const LooseRoute(), const {}, const []), caseSensitive: false),",
            // The root folder's setting is the mount point's.
            "matchRoutes(uri, base, _matchers, caseSensitive: false);",
        ],
    );
    // And the other way round.
    let (c, _) = generated(
        "",
        &[
            ("page.dart", HOME),
            ("ci/route.dart", "const caseSensitive = false;"),
            ("ci/page.dart", &page("Ci")),
        ],
    );
    has(
        &c,
        &[
            "RouteMatcher(['ci'], (s) => UrlMatch(s.uri, const CiRoute(), const {}, const []), caseSensitive: false),",
            "matchRoutes(uri, base, _matchers);",
        ],
    );
}

#[test]
fn a_typed_catch_all_is_parsed_by_the_matcher_like_the_page_does() {
    let c = code(&[
        (
            "compare/$$ids/data.dart",
            "Future<int> data(Ref ref, {required List<int> ids}) async => 1;",
        ),
        (
            "compare/$$ids/page.dart",
            &widget(
                "ComparePage",
                "final List<int> ids; final int n;",
                ", required this.ids, required this.n",
            ),
        ),
    ]);
    has(
        &c,
        &[
            "(ids: Segment.asIntRest(s, 'ids'))",
            "RouteMatcher(['compare', '*ids'], (s) {",
            // A part that isn't an int throws BadSegment in the parser: matchRoutes turns it into null.
            "CompareRoute(ids: p.ids), {'ids': p.ids}, [_data2(restKey(p.ids))])",
        ],
    );
}

#[test]
fn an_app_without_routes_still_generates_an_empty_matcher_list() {
    let (c, _) = generated("", &[("layout.dart", LAYOUT)]);
    has(&c, &["static final List<RouteMatcher> _matchers = [\n  ];"]);
}

#[test]
fn a_separate_manifest_library_has_match_and_the_router_file_has_matchurl() {
    let (main, manifest) = generated(
        "fespalier:\n  output_manifest: lib/app.routes.g.dart\n",
        &[("page.dart", HOME), ("about/page.dart", &page("About"))],
    );
    // app.g.dart doesn't know the manifest: what it can say without it is the URL match.
    has(
        &main,
        &["static UrlMatch? matchUrl(Uri uri)", "dataAt(Uri uri)"],
    );
    lacks(&main, &["RouteMatch?", "RouteMatch(", "AppManifest"]);
    let m = manifest.unwrap();
    has(
        &m,
        &[
            "static RouteMatch? match(Uri uri) {",
            "AppRoutes.matchUrl(uri)",
        ],
    );
}

// --- a section's typed handle -------------------------------------------------------------

fn team_files() -> Vec<(&'static str, String)> {
    vec![
        (
            "teams/$teamId/data.dart",
            "Future<Team> data(Ref ref, {required String teamId}) async => Team();".into(),
        ),
        (
            "teams/$teamId/layout.dart",
            widget(
                "TeamLayout",
                "final Widget child; final Team team;",
                ", required this.child, required this.team",
            ),
        ),
        ("teams/$teamId/members/page.dart", page("Members")),
    ]
}

fn refs<'a>(files: &'a [(&'static str, String)]) -> Vec<(&'static str, &'a str)> {
    files.iter().map(|(a, b)| (*a, b.as_str())).collect()
}

#[test]
fn a_section_gets_a_typed_handle_named_after_its_folder() {
    let c = code(&refs(&team_files()));
    has(
        &c,
        &[
            "abstract final class TeamsTeamIdSection {",
            "static final data = _data2;",
            "static final watch = (WidgetRef ref, {required String teamId}) => ref.watch(data(teamId));",
            "static final read = (WidgetRef ref, {required String teamId}) => ref.readData(data(teamId));",
            "static PrefetchHandle prefetch(WidgetRef ref, {required String teamId, Duration? keepFor}) => ref.prefetchData(data(teamId), keepFor: keepFor);",
            "static Future<void> refresh(WidgetRef ref, {required String teamId}) => ref.refresh(data(teamId).future);",
        ],
    );
    // The section is not a route.
    lacks(&c, &["class TeamsTeamIdRoute"]);
}

#[test]
fn section_handle_names_come_from_the_folder_and_clashes_are_errors() {
    let data = "Future<int> data(Ref ref) async => 1;";
    let c = code(&[
        ("data.dart", data),
        ("layout.dart", LAYOUT),
        ("(shop)/data.dart", data),
        ("(shop)/layout.dart", LAYOUT),
        ("(shop)/cart/page.dart", &page("Cart")),
    ]);
    has(
        &c,
        &[
            "abstract final class RootSection {",
            "abstract final class ShopSection {",
            "static final watch = (WidgetRef ref) => ref.watch(data);",
        ],
    );
    // Two folders that name the same handle.
    let e = errors(
        "",
        &[
            ("a-b/data.dart", data),
            ("a-b/layout.dart", LAYOUT),
            ("a-b/one/page.dart", &page("One")),
            ("a_b/data.dart", data),
            ("a_b/layout.dart", LAYOUT),
            ("a_b/two/page.dart", &page("Two")),
        ],
    )
    .join("\n");
    assert!(
        e.contains("the section's typed handle `ABSection` is already taken by a-b/data.dart"),
        "{e}"
    );
}

#[test]
fn a_section_selector_gets_the_selected_helpers() {
    let c = code(&[
        (
            "teams/$teamId/data.dart",
            "ProviderListenable<AsyncValue<Team>> data({required String teamId}) => teamProvider(teamId);",
        ),
        (
            "teams/$teamId/layout.dart",
            &widget(
                "TeamLayout",
                "final Widget child; final Team team;",
                ", required this.child, required this.team",
            ),
        ),
        ("teams/$teamId/members/page.dart", &page("Members")),
    ]);
    has(
        &c,
        &[
            "static final data = _data2;",
            "ref.readSelected(data(teamId))",
            "static Future<void> refresh(WidgetRef ref, {required String teamId}) => ref.refreshSelected(data(teamId));",
        ],
    );
}

// --- a section keyed by query parameters --------------------------------------------------

fn report_files() -> Vec<(&'static str, String)> {
    vec![
        ("reports/data.dart", "Future<String> data(Ref ref, {String? period, List<String> tags = const []}) async => '';".into()),
        ("reports/layout.dart", widget("ReportsLayout", "final Widget child; final String data;", ", required this.child, required this.data")),
        ("reports/monthly/page.dart", widget("MonthlyPage", "final String data;", ", required this.data")),
        ("reports/yearly/page.dart", page("Yearly")),
    ]
}

#[test]
fn a_section_can_be_keyed_by_query_parameters() {
    let files = report_files();
    let e = errors("", &refs(&files));
    assert!(e.is_empty(), "{e:?}");
    let c = code(&refs(&files));
    has(
        &c,
        &[
            // The section's layout reads them from the URL, as any layout's query parameters.
            "({String? period, List<String> tags}) _layout1(GoRouterState s) => (period: Query.asString(s, 'period'), tags: Query.asStringList(s, 'tags'));",
            "watch: (ref) => ref.watch(_data1((period: v.period, tags: QueryList(v.tags)))),",
            // Every route below is keyed by them too, so its typed route can write them.
            "const MonthlyRoute({this.period, this.tags = const []});",
            "const YearlyRoute({this.period, this.tags = const []});",
            "withQuery(joinLocation(AppRoutes.base, '/reports/monthly'), {'period': period, 'tags': tags})",
            // dataAt reads them from the location.
            "MonthlyRoute(period: p.period, tags: p.tags), {'period': p.period, 'tags': p.tags}, [_data1((period: p.period, tags: QueryList(p.tags)))])",
            // The typed handle takes them as named parameters.
            "static final watch = (WidgetRef ref, {String? period, List<String> tags = const []}) => ref.watch(data((period: period, tags: QueryList(tags))));",
        ],
    );
}

#[test]
fn a_route_preloads_its_own_data_and_its_sections() {
    let c = code(&[
        ("page.dart", HOME),
        (
            "teams/$teamId/data.dart",
            "Future<String> data(Ref ref, {required String teamId}) async => '';",
        ),
        (
            "teams/$teamId/layout.dart",
            &widget(
                "TeamLayout",
                "final Widget child; final String data;",
                ", required this.child, required this.data",
            ),
        ),
        ("teams/$teamId/members/page.dart", &page("Members")),
        (
            "teams/$teamId/stats/data.dart",
            "Future<int> data(Ref ref, {required String teamId, int? week}) async => 1;",
        ),
        (
            "teams/$teamId/stats/page.dart",
            &widget("StatsPage", "final int n;", ", required this.n"),
        ),
    ]);
    has(
        &c,
        &[
            // The section's provider, then the route's own: what `dataAt` lists.
            "PrefetchHandle preload(WidgetRef ref, {Duration? keepFor}) => ref.prefetchAll([_data2(teamId), _data4((teamId: teamId, week: week))], keepFor: keepFor);",
            // A route that only has the section's data still starts it.
            "PrefetchHandle preload(WidgetRef ref, {Duration? keepFor}) => ref.prefetchAll([_data2(teamId)], keepFor: keepFor);",
            // By location.
            "static PrefetchHandle preload(WidgetRef ref, Uri uri, {Duration? keepFor}) => ref.prefetchAll(dataAt(uri) ?? const [], keepFor: keepFor);",
        ],
    );
    // The matcher and `preload` list the same providers.
    has(
        &c,
        &["[_data2(p.teamId), _data4((teamId: p.teamId, week: p.week))])"],
    );
    // HomeRoute has no data: it inherits the base's no-op.
    assert_eq!(
        c.matches("@override\n  PrefetchHandle preload(").count(),
        2,
        "{c}"
    );
}

#[test]
fn preload_is_a_member_of_the_route_class_so_it_is_reserved() {
    let e = errors(
        "",
        &[(
            "$preload/page.dart",
            &widget("PPage", "final String preload;", ", required this.preload"),
        )],
    )
    .join("\n");
    assert!(e.contains("`$preload` is reserved"), "{e}");
}

#[test]
fn a_section_selector_can_take_query_parameters_too() {
    let files = [
        (
            "teams/$teamId/data.dart",
            "ProviderListenable<AsyncValue<Team>> data({required String teamId, String? tab}) => teamProvider(teamId, tab);",
        ),
        (
            "teams/$teamId/layout.dart",
            &widget(
                "TeamLayout",
                "final Widget child; final Team team;",
                ", required this.child, required this.team",
            ),
        ),
        ("teams/$teamId/members/page.dart", &page("Members")),
    ];
    let e = errors("", &files);
    assert!(e.is_empty(), "{e:?}");
    let c = code(&files);
    has(
        &c,
        &[
            // The query parameter is a field of every route below the section.
            "const MembersRoute({required this.teamId, this.tab});",
            "ref.readSelected(data((teamId: teamId, tab: tab)))",
            "{required String teamId, String? tab}) => ref.refreshSelected(data((teamId: teamId, tab: tab)))",
        ],
    );
}

#[test]
fn a_query_key_of_a_section_must_agree_with_a_pages_own() {
    let mut files = report_files();
    files[2].1 = widget(
        "MonthlyPage",
        "final String data; final int? period;",
        ", required this.data, this.period",
    );
    let e = errors("", &refs(&files)).join("\n");
    // The page's own `int? period` and the section's `String? period` are one query parameter.
    assert!(
        e.contains("`?period` is int? in reports/monthly/page.dart")
            && e.contains("but String? here"),
        "{e}"
    );
    assert!(e.contains("reports/data.dart"), "{e}");
}

#[test]
fn section_keys_cannot_shadow_the_handles_members() {
    let e = errors(
        "",
        &[
            (
                "s/data.dart",
                "Future<int> data(Ref ref, {String? ref2, int? keepFor}) async => 1;",
            ),
            ("s/layout.dart", LAYOUT),
            ("s/x/page.dart", &page("X")),
        ],
    )
    .join("\n");
    assert!(
        e.contains("`keepFor` can't be a key of a section's data.dart"),
        "{e}"
    );
}

// --- meta_unique ----------------------------------------------------------------------------

fn meta(args: &str) -> String {
    format!(
        "class Meta {{ const Meta({{this.code, this.slug, this.n}}); final String? code; final String? slug; final int? n; }}\nconst meta = Meta({args});"
    )
}

const UNIQUE: &str = "fespalier:\n  meta_unique: [code, slug]\n";

#[test]
fn meta_unique_is_a_config_key() {
    assert!(
        Pubspec::parse("name: a\n")
            .unwrap()
            .config
            .meta_unique
            .is_empty()
    );
    let c = Pubspec::parse("name: a\nfespalier:\n  meta_unique: [code, slug, code]\n")
        .unwrap()
        .config;
    assert_eq!(c.meta_unique, ["code", "slug"]);
    let e = Pubspec::parse("name: a\nfespalier:\n  meta_unique: ['not an ident']\n").unwrap_err();
    assert!(format!("{e:#}").contains("not an ident"), "{e:#}");
}

#[test]
fn duplicate_literals_are_errors_that_name_both_files() {
    let e = errors(
        UNIQUE,
        &[
            ("page.dart", HOME),
            ("meta.dart", &meta("code: 'A01', slug: 'home'")),
            ("about/page.dart", &page("About")),
            ("about/meta.dart", &meta("code: 'A01', slug: 'about'")),
            ("blog/page.dart", &page("Blog")),
            ("blog/meta.dart", &meta("code: 'B01', slug: 'home'")),
        ],
    );
    assert_eq!(e.len(), 2, "{e:?}");
    let all = e.join("\n");
    assert!(
        all.contains("about/meta.dart") && all.contains("`code: 'A01'` is also in meta.dart"),
        "{all}"
    );
    assert!(
        all.contains("blog/meta.dart") && all.contains("`slug: 'home'` is also in meta.dart"),
        "{all}"
    );
    assert!(all.contains("meta_unique: [code, slug]"), "{all}");
}

#[test]
fn different_literals_expressions_and_missing_arguments_say_nothing() {
    let e = diags(
        UNIQUE,
        &[
            ("page.dart", HOME),
            ("meta.dart", &meta("code: 'A01'")),
            ("a/page.dart", &page("A")),
            ("a/meta.dart", &meta("code: 'A02'")),
            // Not a literal: nothing to compare (two of them are not duplicates of each other).
            ("b/page.dart", &page("B")),
            ("b/meta.dart", &meta("code: prefix + 'x'")),
            ("c/page.dart", &page("C")),
            ("c/meta.dart", &meta("code: prefix + 'x'")),
            // Left out, twice.
            ("d/page.dart", &page("D")),
            ("d/meta.dart", &meta("slug: 's1'")),
            ("e/page.dart", &page("E")),
            ("e/meta.dart", &meta("")),
        ],
    );
    assert!(diags_are_clean(&e), "{e:?}");
}

fn diags_are_clean(d: &[String]) -> bool {
    d.iter().all(|m| !m.starts_with('✗'))
}

#[test]
fn numbers_and_strings_are_different_values_and_numbers_compare_as_written() {
    let e = errors(
        "fespalier:\n  meta_unique: [n]\n",
        &[
            ("page.dart", HOME),
            ("meta.dart", &meta("n: 1_000")),
            ("a/page.dart", &page("A")),
            ("a/meta.dart", &meta("n: 1000")),
            ("b/page.dart", &page("B")),
            ("b/meta.dart", &meta("n: 2")),
        ],
    );
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(e[0].contains("`n: 1000` is also in meta.dart"), "{e:?}");
    let e = errors(
        "fespalier:\n  meta_unique: [n]\n",
        &[
            ("page.dart", HOME),
            ("meta.dart", &meta("n: 1")),
            ("a/page.dart", &page("A")),
            (
                "a/meta.dart",
                "class M { const M({this.n}); final Object? n; }\nconst meta = M(n: '1');",
            ),
        ],
    );
    assert!(e.is_empty(), "{e:?}");
}

#[test]
fn a_key_no_meta_gives_a_literal_is_a_warning() {
    let d = diags(
        "fespalier:\n  meta_unique: [codee]\n",
        &[("page.dart", HOME), ("meta.dart", &meta("code: 'A'"))],
    )
    .join("\n");
    assert!(
        d.contains("`meta_unique` in pubspec.yaml lists `codee`"),
        "{d}"
    );
    assert!(!d.contains('✗'), "{d}");
    // Nothing to say when no route has a meta.dart at all.
    assert!(
        diags(
            "fespalier:\n  meta_unique: [code]\n",
            &[("page.dart", HOME)]
        )
        .is_empty()
    );
}

#[test]
fn meta_may_be_written_const_and_redirects_count_too() {
    let e = errors(
        "fespalier:\n  meta_unique: [code]\n",
        &[
            ("page.dart", HOME),
            ("meta.dart", "const meta = const Meta(code: 'X');"),
            ("old/redirect.dart", "String redirect() => '/';"),
            ("old/meta.dart", "const meta = Meta(code: 'X');"),
        ],
    );
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(e[0].contains("old/meta.dart"), "{e:?}");
}

// --- not_found.dart takes segments ----------------------------------------------------------

fn not_found(class: &str, fields: &str, params: &str) -> String {
    format!(
        "class {class} extends StatelessWidget {{ const {class}({{super.key, required this.uri{params}}}); final Uri uri; {fields} }}"
    )
}

#[test]
fn a_not_found_gets_its_segments_as_strings() {
    let c = code(&[
        ("page.dart", HOME),
        (
            "shops/$shop/not_found.dart",
            &not_found("ShopNotFound", "final String shop;", ", required this.shop"),
        ),
        (
            "shops/$shop/page.dart",
            &widget("ShopPage", "final int shop;", ", required this.shop"),
        ),
        (
            "shops/$shop/items/$id/page.dart",
            &widget("ItemPage", "final int id;", ", required this.id"),
        ),
    ]);
    has(
        &c,
        &[
            // A route whose segment doesn't parse: the raw value is in the router's parameters.
            "() => _i2.ShopNotFound(uri: state.uri, shop: state.pathParameters['shop']!),",
            // An unknown URL under it: the part of the path at its place.
            "(['shops', ':shop'], (uri) => _i2.ShopNotFound(uri: uri, shop: pathPart(uri, base, 1)), caseSensitive: true),",
        ],
    );
}

#[test]
fn a_not_found_segment_must_be_a_string() {
    let e = errors(
        "",
        &[
            ("page.dart", HOME),
            (
                "shops/$shop/not_found.dart",
                &not_found("ShopNotFound", "final int shop;", ", required this.shop"),
            ),
            (
                "shops/$shop/page.dart",
                &widget("ShopPage", "final int shop;", ", required this.shop"),
            ),
        ],
    )
    .join("\n");
    assert!(
        e.contains("`shop` gets the segment as the URL spells it, a String"),
        "{e}"
    );
    assert!(e.contains("declare it `String shop`"), "{e}");
    // Only the segments of its own path.
    let e = errors(
        "",
        &[
            ("page.dart", HOME),
            (
                "a/not_found.dart",
                &not_found("ANotFound", "final String other;", ", required this.other"),
            ),
            ("a/page.dart", &page("A")),
        ],
    )
    .join("\n");
    assert!(e.contains("can't fill `other`: not_found.dart only gets `Uri uri`, and the segments of its own path as Strings"), "{e}");
}

// --- fsp new --not-found --------------------------------------------------------------------

fn new_args(route: &str, not_found: bool) -> NewArgs {
    NewArgs {
        route: route.into(),
        name: None,
        data: false,
        loading: false,
        error: false,
        layout: false,
        guard: false,
        transition: false,
        function: false,
        not_found,
    }
}

#[test]
fn new_not_found_scaffolds_a_file_that_takes_the_segments() {
    let dir = project("", &[("page.dart", HOME)]);
    let created =
        scaffold::new_route_opts(dir.path(), &new_args("shops/[shop]", true), false).unwrap();
    assert_eq!(
        created,
        [
            "lib/app/shops/$shop/page.dart",
            "lib/app/shops/$shop/not_found.dart"
        ]
    );
    let src = fs::read_to_string(dir.path().join("lib/app/shops/$shop/not_found.dart")).unwrap();
    assert!(
        src.contains("class ShopsShopNotFound extends StatelessWidget"),
        "{src}"
    );
    assert!(
        src.contains("required this.uri, required this.shop") && src.contains("final String shop;"),
        "{src}"
    );
    // What it scaffolds generates cleanly, and is the folder's not-found.
    let cfg = Config::load(dir.path()).unwrap();
    let (code, diags, _) = analyze(&dir.path().join("lib/app"), &cfg).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    has(
        &code,
        &["ShopsShopNotFound(uri: uri, shop: pathPart(uri, base, 1))"],
    );
}

#[test]
fn new_not_found_alone_and_where_it_cannot_go() {
    let dir = project("", &[("page.dart", HOME)]);
    let created = scaffold::new_route_opts(dir.path(), &new_args("docs", true), true).unwrap();
    assert_eq!(created, ["lib/app/docs/not_found.dart"]);
    let src = fs::read_to_string(dir.path().join("lib/app/docs/not_found.dart")).unwrap();
    assert!(
        src.contains("DocsNotFound({super.key, required this.uri})"),
        "{src}"
    );
    // Not for a catch-all: it matches everything below it.
    let e = scaffold::new_route_opts(dir.path(), &new_args("wiki/[...rest]", true), false)
        .unwrap_err()
        .to_string();
    assert!(
        e.contains("catch-all folder can't have a not_found.dart"),
        "{e}"
    );
    // Without the flag nothing changes.
    let created = scaffold::new_route_opts(dir.path(), &new_args("plain", false), false).unwrap();
    assert_eq!(created, ["lib/app/plain/page.dart"]);
}

// --- the Dart reader ------------------------------------------------------------------------

#[test]
fn constructor_call_arguments_are_read_as_literals() {
    use crate::dart::{Lit, parse};
    let m = parse(
        r#"
        const a = PageMeta(code: 'A01', order: 3, ratio: -1.5, hex: 0xff, flag: true, title: 'x $y', other: kSomething, 'positional');
        const b = const PageMeta(code: "B");
        const c = PageMeta();
        const d = 'not a call';
        "#,
    );
    let var = |n: &str| m.variables.iter().find(|v| v.name == n).unwrap();
    let a: Vec<(String, Lit)> = var("a")
        .ctor_args
        .as_ref()
        .unwrap()
        .iter()
        .map(|x| (x.name.clone(), x.value.clone()))
        .collect();
    assert_eq!(
        a,
        [
            ("code".to_string(), Lit::Str("A01".into())),
            ("order".to_string(), Lit::Num("3".into())),
            ("ratio".to_string(), Lit::Num("-1.5".into())),
            ("hex".to_string(), Lit::Num("0xff".into())),
            ("flag".to_string(), Lit::Bool(true)),
            ("title".to_string(), Lit::Other),
            ("other".to_string(), Lit::Other),
        ]
    );
    assert_eq!(
        var("b").ctor_args.as_ref().unwrap()[0].value,
        Lit::Str("B".into())
    );
    assert!(var("c").ctor_args.as_ref().unwrap().is_empty());
    assert!(var("d").ctor_args.is_none());
}
