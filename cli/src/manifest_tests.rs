//! The route manifest, `meta.dart`, `output_manifest:` and restoration ids.
//! (The rest of the generator's tests are in `tests.rs`.)

use std::fs;

use crate::config::Config;
use crate::{analyze, gen, manifest};

const HOME: &str = "class HomePage extends StatelessWidget { const HomePage({super.key}); }";
const LAYOUT: &str = "class ShopLayout extends StatelessWidget { const ShopLayout({super.key, required this.child}); final Widget child; }";
const TABS: &str = "class TabsLayout extends StatelessWidget { const TabsLayout({super.key, required this.shell}); final StatefulNavigationShell shell; }\nconst tabs = ['search', '.', '(more)'];";

fn page(name: &str) -> String {
    format!("class {name}Page extends StatelessWidget {{ const {name}Page({{super.key}}); }}")
}

/// A throwaway project whose pubspec carries `yaml` (extra top-level keys).
fn project(yaml: &str, files: &[(&str, &str)]) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("pubspec.yaml"), format!("name: demo\n{yaml}")).unwrap();
    for (rel, body) in files {
        let p = dir.path().join("lib/app").join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, body).unwrap();
    }
    dir
}

/// Diagnostics as `✗ file:line  message`, for the project as configured.
fn diags(yaml: &str, files: &[(&str, &str)]) -> Vec<String> {
    let dir = project(yaml, files);
    let cfg = Config::load(dir.path()).unwrap();
    let (_, diags, _) = analyze(&dir.path().join("lib/app"), &cfg).unwrap();
    diags.0.iter().map(|d| d.to_string()).collect()
}

/// The generated files of a project that checks cleanly: (`output`, manifest library).
fn generated(yaml: &str, files: &[(&str, &str)]) -> (String, Option<String>) {
    let dir = project(yaml, files);
    let cfg = Config::load(dir.path()).unwrap();
    let (code, diags, app) = analyze(&dir.path().join("lib/app"), &cfg).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    (code, manifest::emit(&app, &cfg))
}

fn has(code: &str, needles: &[&str]) {
    for n in needles {
        assert!(code.contains(n), "missing `{n}` in:\n{code}");
    }
}

// --- the manifest ------------------------------------------------------------

#[test]
fn every_route_is_listed_with_what_the_generator_knows() {
    let (c, separate) = generated(
        "",
        &[
            ("page.dart", HOME),
            ("(buyer)/layout.dart", LAYOUT),
            ("(buyer)/products/$id/page.dart", "class ProductPage extends StatelessWidget { const ProductPage({super.key, required this.id, this.tab, required this.data}); final int id; final String? tab; final Item data; }"),
            ("(buyer)/products/$id/data.dart", "Future<Item> data(Ref ref, {required int id}) async => x;"),
            ("old/redirect.dart", "String redirect() => '/';"),
        ],
    );
    assert!(separate.is_none());
    has(
        &c,
        &[
            "abstract final class AppManifest {",
            "static const List<RouteInfo<Object?>> all = [",
            "type: HomeRoute,\n      path: '/',\n      folder: '',\n    ),",
            // The route's own facts: folder, groups (as written), layouts, segments, query, data keys.
            "type: ProductRoute,\n      path: '/products/:id',\n      folder: '(buyer)/products/\\$id',\n      groups: ['(buyer)'],\n      layouts: ['(buyer)'],\n      segments: [RouteParam('id', 'int')],\n      query: [RouteParam('tab', 'String?')],\n      dataKeys: ['id'],\n    ),",
            // A redirect.dart route says so.
            "type: OldRoute,\n      path: '/old',\n      folder: 'old',\n      presentation: RoutePresentation.redirect,\n    ),",
            "static final Map<Type, RouteInfo<Object?>> byType",
            "static final Map<String, RouteInfo<Object?>> byPath",
            "static RouteInfo<Object?>? of(GoRouterState state)",
            // AppRoutes forwards to it, so `AppRoutes.byType[...]` works.
            "static List<RouteInfo<Object?>> get all => AppManifest.all;",
            "static Map<Type, RouteInfo<Object?>> get byType => AppManifest.byType;",
            "static Map<String, RouteInfo<Object?>> get byPath => AppManifest.byPath;",
        ],
    );
}

#[test]
fn tab_membership_follows_the_tabs_order_and_nests() {
    let (c, _) = generated(
        "",
        &[
            ("layout.dart", TABS),
            ("page.dart", HOME),
            ("search/page.dart", &page("Search")),
            ("(more)/settings/page.dart", &page("Settings")),
            ("(more)/settings/deep/page.dart", &page("Deep")),
        ],
    );
    has(
        &c,
        &[
            // `tabs` puts search first, the layout's own page second, `(more)` last.
            "type: SearchRoute,\n      path: '/search',\n      folder: 'search',\n      layouts: [''],\n      tabs: [RouteTab('', 0, 'search')],",
            "type: HomeRoute,\n      path: '/',\n      folder: '',\n      layouts: [''],\n      tabs: [RouteTab('', 1, '.')],",
            "type: SettingsRoute,\n      path: '/settings',\n      folder: '(more)/settings',\n      groups: ['(more)'],\n      layouts: [''],\n      tabs: [RouteTab('', 2, '(more)')],",
            "type: DeepRoute,\n      path: '/settings/deep',\n      folder: '(more)/settings/deep',\n      groups: ['(more)'],\n      layouts: [''],\n      tabs: [RouteTab('', 2, '(more)')],",
        ],
    );
}

#[test]
fn meta_dart_is_passed_through_by_import_and_never_respelled() {
    let (c, _) = generated(
        "",
        &[
            ("page.dart", HOME),
            ("meta.dart", "import 'package:demo/page_meta.dart';\nconst meta = PageMeta(code: 'A01', title: 'Home');"),
            ("about/page.dart", &page("About")),
            ("$id/page.dart", &page("Item")),
            ("$id/meta.dart", "const meta = <String>['a', 'b'];"),
        ],
    );
    // Each meta.dart is imported after the app's own files, and referenced as `_iN.meta`.
    has(&c, &["import 'app/meta.dart' as _i", "import 'app/\\$id/meta.dart' as _i"]);
    assert!(!c.contains("PageMeta("), "the meta expression must not be re-spelled:\n{c}");
    assert!(!c.contains("'A01'"), "{c}");
    let imports: Vec<&str> = c.lines().filter(|l| l.starts_with("import 'app/")).collect();
    let meta_ix = |file: &str| {
        let line = imports.iter().find(|l| l.contains(file)).unwrap();
        line.rsplit("as _i").next().unwrap().trim_end_matches(';').to_string()
    };
    has(&c, &[&format!("meta: _i{}.meta,", meta_ix("app/meta.dart")), &format!("meta: _i{}.meta,", meta_ix("app/\\$id/meta.dart"))]);
    // A route without a meta.dart lists none, and nothing is inherited.
    let about = &c[c.find("type: AboutRoute,").unwrap()..];
    assert!(!about[..about.find("),\n").unwrap()].contains("meta:"), "{c}");
}

#[test]
fn meta_belongs_to_the_route_alone_a_redirect_can_have_one() {
    let (c, _) = generated(
        "",
        &[
            ("page.dart", HOME),
            ("meta.dart", "const meta = 'home';"),
            ("old/redirect.dart", "String redirect() => '/';"),
            ("old/meta.dart", "const meta = 'old';"),
            ("old/below/page.dart", &page("Below")),
        ],
    );
    assert_eq!(c.matches("meta: _i").count(), 2, "{c}");
}

// --- meta.dart errors --------------------------------------------------------

#[test]
fn a_non_const_meta_is_an_error_at_its_declaration() {
    for decl in ["final meta = 1;", "var meta = 1;", "late final meta = 1;", "final PageMeta meta = PageMeta();"] {
        let d = diags("", &[("page.dart", HOME), ("meta.dart", &format!("class PageMeta {{ const PageMeta(); }}\n\n{decl}"))]);
        assert_eq!(d.len(), 1, "{decl}: {d:?}");
        assert!(d[0].starts_with("✗ meta.dart:3  `meta` must be `const`"), "{decl}: {d:?}");
    }
    // The declaration is what is checked, not what it holds.
    assert!(diags("", &[("page.dart", HOME), ("meta.dart", "const meta = PageMeta(code: 'A01');")]).is_empty());
    assert!(diags("", &[("page.dart", HOME), ("meta.dart", "const PageMeta meta = PageMeta();")]).is_empty());
}

#[test]
fn meta_dart_must_declare_meta() {
    let d = diags("", &[("page.dart", HOME), ("meta.dart", "const other = 1;")]);
    assert_eq!(d, vec!["✗ meta.dart  expected `const meta = <a const expression>;`"]);
    // A getter or function is not a const variable either.
    let d = diags("", &[("page.dart", HOME), ("meta.dart", "int get meta => 1;")]);
    assert_eq!(d, vec!["✗ meta.dart  expected `const meta = <a const expression>;`"]);
    // Declared twice: Dart would say so too, but the manifest can't pick one.
    let d = diags("", &[("page.dart", HOME), ("meta.dart", "const meta = 1;\nconst meta = 2;")]);
    assert_eq!(d, vec!["✗ meta.dart:2  `meta` is declared twice"]);
}

#[test]
fn a_meta_dart_without_a_route_is_ignored_with_a_warning() {
    let d = diags("", &[("page.dart", HOME), ("(group)/meta.dart", "const meta = 1;"), ("(group)/x/page.dart", &page("X"))]);
    assert_eq!(d.len(), 1, "{d:?}");
    assert!(d[0].starts_with("! (group)/meta.dart") && d[0].contains("no page.dart or redirect.dart"), "{d:?}");
    // And it is not imported.
    let (c, _) = generated("", &[("page.dart", HOME)]);
    assert!(!c.contains("meta.dart' as"), "{c}");
}

#[test]
fn meta_required_names_the_folder_without_a_meta_dart() {
    let files = [
        ("page.dart", HOME),
        ("meta.dart", "const meta = 1;"),
        ("products/$id/page.dart", &page("Product") as &str),
        ("about/page.dart", &page("About")),
        ("about/meta.dart", "const meta = 2;"),
        ("old/redirect.dart", "String redirect() => '/';"),
    ];
    // Optional by default, and when asked for.
    assert!(diags("", &files).is_empty());
    assert!(diags("fespalier:\n  meta: optional\n", &files).is_empty());

    let d = diags("fespalier:\n  meta: required\n", &files);
    assert_eq!(d.len(), 2, "{d:?}");
    assert!(
        d[1].starts_with("✗ products/$id/page.dart:1  `products/$id/` has no meta.dart, and `fespalier: meta: required`"),
        "{d:?}"
    );
    // A redirect.dart route needs one too.
    assert!(d[0].starts_with("✗ old/redirect.dart") && d[0].contains("`old/` has no meta.dart"), "{d:?}");

    // The app folder itself, for the root page.
    let d = diags("fespalier:\n  meta: required\n", &[("page.dart", HOME)]);
    assert!(d[0].contains("the app folder has no meta.dart"), "{d:?}");

    // A folder whose meta.dart is broken gets that error, not a second one.
    let d = diags("fespalier:\n  meta: required\n", &[("page.dart", HOME), ("meta.dart", "final meta = 1;")]);
    assert_eq!(d.len(), 1, "{d:?}");
    assert!(d[0].contains("must be `const`"), "{d:?}");
}

#[test]
fn meta_required_stops_gen_without_touching_the_output() {
    let dir = project("fespalier:\n  meta: required\n", &[("page.dart", HOME)]);
    let e = gen(dir.path(), true).unwrap_err().to_string();
    assert!(e.contains("1 error(s)") && e.contains("lib/app.g.dart left unchanged"), "{e}");
    assert!(!dir.path().join("lib/app.g.dart").exists());
}

// --- output_manifest -----------------------------------------------------------

#[test]
fn config_reads_output_manifest_and_meta() {
    let c = |yaml: &str| crate::config::Pubspec::parse(yaml).map(|p| p.config);
    let cfg = c("name: demo\nfespalier:\n  output_manifest: lib/app.routes.g.dart\n  meta: required\n").unwrap();
    assert_eq!(cfg.output_manifest.as_deref(), Some("lib/app.routes.g.dart"));
    assert!(cfg.meta_required);
    assert_eq!(cfg.output_from_manifest().as_deref(), Some("app.g.dart"));
    assert_eq!(Config::default().output_manifest, None);
    assert!(!Config::default().meta_required);

    // Paths are relative to each other.
    let cfg = c("fespalier:\n  output: lib/router/app.g.dart\n  output_manifest: lib/review/routes.g.dart\n").unwrap();
    assert_eq!(cfg.output_from_manifest().as_deref(), Some("../router/app.g.dart"));
    assert_eq!(cfg.import_path_from_manifest("page.dart"), "../app/page.dart");

    for (yaml, want) in [
        ("fespalier:\n  output_manifest: app.routes.g.dart\n", "`fespalier.output_manifest` must be a path under lib/"),
        ("fespalier:\n  output_manifest: lib/routes\n", "`fespalier.output_manifest` must be a .dart file"),
        ("fespalier:\n  output_manifest: lib/app.g.dart\n", "are the same file"),
        ("fespalier:\n  meta: always\n", "`fespalier.meta` must be `required` or `optional`, got `always`"),
    ] {
        let e = format!("{:#}", c(yaml).unwrap_err());
        assert!(e.contains(want), "{yaml}: {e}");
    }
}

#[test]
fn the_manifest_can_be_its_own_library() {
    let (main, separate) = generated(
        "fespalier:\n  output_manifest: lib/app.routes.g.dart\n",
        &[("page.dart", HOME), ("meta.dart", "const meta = 'home';"), ("about/page.dart", &page("About"))],
    );
    let manifest = separate.expect("output_manifest writes a second library");
    // app.g.dart has no manifest and doesn't import meta.dart: production code can import it alone.
    assert!(!main.contains("meta.dart") && !main.contains("AppManifest") && !main.contains("RouteInfo"), "{main}");
    assert!(!main.contains("get byType"), "{main}");
    // The manifest imports the typed routes from it, and the meta files as `_iN`.
    has(
        &manifest,
        &[
            "// GENERATED by fespalier from lib/app/. Do not edit; run `fsp gen`.",
            "import 'package:fespalier/fespalier.dart';",
            "import 'app.g.dart';",
            "import 'app/meta.dart' as _i0;",
            "abstract final class AppManifest {",
            "type: HomeRoute,\n      path: '/',\n      folder: '',\n      meta: _i0.meta,\n    ),",
            "type: AboutRoute,\n      path: '/about',\n      folder: 'about',\n    ),",
        ],
    );
    // No AppRoutes forwarding in the manifest library (it can't add to another file's class).
    assert!(!manifest.contains("abstract final class AppRoutes"), "{manifest}");
    // The routes themselves are unchanged.
    has(&main, &["final class HomeRoute extends TypedLocation {", "final class AboutRoute extends TypedLocation {"]);
}

#[test]
fn a_separate_manifest_finds_the_app_and_the_output_from_where_it_sits() {
    let (_, separate) = generated(
        "fespalier:\n  output: lib/router/app.g.dart\n  output_manifest: lib/review/routes.g.dart\n",
        &[("page.dart", HOME), ("meta.dart", "const meta = 1;")],
    );
    has(&separate.unwrap(), &["import '../router/app.g.dart';", "import '../app/meta.dart' as _i0;"]);
}

#[test]
fn gen_writes_both_files_and_reports_both() {
    let dir = project("fespalier:\n  output_manifest: lib/app.routes.g.dart\n", &[("page.dart", HOME)]);
    let o = gen(dir.path(), true).unwrap();
    assert_eq!(o.line(), "✓ 1 route → lib/app.g.dart, lib/app.routes.g.dart");
    assert!(dir.path().join("lib/app.g.dart").exists() && dir.path().join("lib/app.routes.g.dart").exists());
    assert_eq!(gen(dir.path(), true).unwrap().line(), "✓ 1 route, lib/app.g.dart, lib/app.routes.g.dart unchanged");

    // Either file being out of date is written again.
    fs::write(dir.path().join("lib/app.routes.g.dart"), "// stale").unwrap();
    assert!(gen(dir.path(), true).unwrap().wrote);
    assert!(fs::read_to_string(dir.path().join("lib/app.routes.g.dart")).unwrap().contains("AppManifest"));

    // `check` writes nothing.
    fs::remove_file(dir.path().join("lib/app.routes.g.dart")).unwrap();
    assert!(!gen(dir.path(), false).unwrap().wrote);
    assert!(!dir.path().join("lib/app.routes.g.dart").exists());
}

#[test]
fn errors_leave_both_files_untouched() {
    let dir = project("fespalier:\n  output_manifest: lib/app.routes.g.dart\n", &[("page.dart", HOME), ("meta.dart", "final meta = 1;")]);
    let e = gen(dir.path(), true).unwrap_err().to_string();
    assert!(e.contains("lib/app.g.dart and lib/app.routes.g.dart left unchanged"), "{e}");
    assert!(!dir.path().join("lib/app.g.dart").exists() && !dir.path().join("lib/app.routes.g.dart").exists());
}

// --- restoration ---------------------------------------------------------------

#[test]
fn the_router_takes_a_restoration_scope_id() {
    let (c, _) = generated("", &[("page.dart", HOME)]);
    has(
        &c,
        &[
            "String? restorationScopeId,\n  }) =>",
            "restorationScopeId: restorationScopeId,\n        routes: mount(),",
        ],
    );
}

#[test]
fn layouts_get_stable_restoration_ids_from_their_folders() {
    let (c, _) = generated(
        "",
        &[
            ("layout.dart", TABS),
            ("page.dart", HOME),
            ("search/page.dart", &page("Search")),
            ("(more)/hub/page.dart", &page("Hub")),
            ("(more)/shop/layout.dart", LAYOUT),
            ("(more)/shop/items/page.dart", &page("Items")),
        ],
    );
    has(
        &c,
        &[
            // The shell's page, and its Navigator, from the layout's folder.
            "pageBuilder: (context, state, navigationShell) => layoutPage(\n          context,\n          state,\n          'layout:/',",
            "restorationScopeId: 'layout:/',\n      ),",
            // One id per tab, from the folder (`.` is the layout's own page).
            "restorationScopeId: 'tab:/search',",
            "restorationScopeId: 'tab:/.',",
            "restorationScopeId: 'tab:/(more)',",
            // A plain layout too.
            "ShellRoute(\n                pageBuilder: (context, state, child) => layoutPage(\n                  context,\n                  state,\n                  'layout:(more)/shop/',",
            "restorationScopeId: 'layout:(more)/shop/',",
        ],
    );
    // The ids are unique among the routes of one navigator.
    let ids: Vec<&str> = c.lines().filter(|l| l.trim_start().starts_with("restorationScopeId: 'tab:")).collect();
    let mut sorted = ids.clone();
    sorted.sort_unstable();
    sorted.dedup();
    assert_eq!(ids.len(), sorted.len(), "{ids:?}");
}

#[test]
fn restoration_ids_escape_dollar_signs() {
    let (c, _) = generated("", &[("page.dart", HOME), ("$shop/layout.dart", LAYOUT), ("$shop/page.dart", &page("Shop"))]);
    has(&c, &["'layout:\\$shop/'"]);
}
