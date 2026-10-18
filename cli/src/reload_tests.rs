//! The hot reload's two const slots in the generated `app.g.dart` (since 0.19.0): `reload.rs` reads
//! the fields a reload keeps, and `emit.rs` stamps `_version` and `_kept`. The router and the
//! manifest the reload rebuilds are checked here too, against the same project as `match_tests.rs`.

use std::collections::BTreeMap;
use std::fs;

use crate::config::Config;
use crate::reload::{kept_fields, stamp};
use crate::{analyze, manifest};

const HOME: &str = "class HomePage extends StatelessWidget { const HomePage({super.key}); }";

const LAYOUT: &str = "class SLayout extends StatelessWidget { const SLayout({super.key, required this.child}); final Widget child; }";

const TABS: &str = "const tabs = ['a', 'b'];\nclass TabsLayout extends StatelessWidget { const TabsLayout({super.key, required this.navigationShell}); final StatefulNavigationShell navigationShell; }";

const CODEC: &str =
    "import 'package:fespalier/fespalier.dart';\nfinal extraCodec = ExtraCodec({});";

const OBSERVE: &str = "void onEnter(Ref ref, {required TypedLocation route}) {}\n";

fn page(name: &str) -> String {
    format!("class {name}Page extends StatelessWidget {{ const {name}Page({{super.key}}); }}")
}

fn data(name: &str) -> String {
    format!("Future<{name}> data(Ref ref, {{required int id}}) async => 0;")
}

/// A page that takes what its `data.dart` yields (an `int`), as the generator asks.
fn item() -> String {
    "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.data}); final int data; }".to_string()
}

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

/// The generated `app.g.dart` and the separate manifest library, of a project that checks cleanly.
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

/// The text from the first line that contains [start] to the first line after it that is [end].
fn section<'a>(code: &'a str, start: &str, end: &str) -> &'a str {
    let from = code.find(start).unwrap_or_else(|| panic!("no `{start}`"));
    let rest = &code[from..];
    let to = rest.find(end).unwrap_or_else(|| panic!("no `{end}`"));
    &rest[..to]
}

/// The `_kept` map of a generated file, by name.
fn kept_of(code: &str) -> BTreeMap<String, String> {
    let body = section(code, "static const Map<String, String> _kept = {", "\n  };");
    body.lines()
        .skip(1)
        .filter_map(|line| {
            let (name, hash) = line.trim().trim_end_matches(',').split_once(": ")?;
            Some((
                name.trim_matches('\'').to_string(),
                hash.trim_matches('\'').to_string(),
            ))
        })
        .collect()
}

fn version_of(code: &str) -> String {
    let at = code
        .find("static const String _version = '")
        .expect("a _version");
    code[at + "static const String _version = '".len()..][..16].to_string()
}

fn is_hex(s: &str) -> bool {
    s.chars()
        .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
}

/// The fields of a file that a hot reload keeps, as the names and their declarations.
fn fields(src: &str) -> BTreeMap<String, String> {
    kept_fields(src, &[]).into_iter().collect()
}

#[test]
fn kept_fields_reads_top_level_and_static_finals() {
    let src = "\
import 'a.dart';
final _lib2 = DeferredLibrary(_i3.loadLibrary, 'a;b');
final _data6 = cachedData(
  (id) => traceData(ref, 'site;one', _i1.data(id)),
);
abstract final class AppRoutes {
  static final deferred = [_lib2];
  static final _rootNavigatorKey = 1;
}
final class ProductRoute extends TypedLocation {
  static final data = _data6;
}
abstract final class AppAdapters {
  static final _all = FespalierAdapters([]);
}
";
    let names: Vec<String> = kept_fields(src, &[]).into_iter().map(|(n, _)| n).collect();
    assert_eq!(
        names,
        [
            "_lib2",
            "_data6",
            "AppRoutes.deferred",
            "AppRoutes._rootNavigatorKey",
            "ProductRoute.data",
            "AppAdapters._all",
        ],
    );
    // The `;` inside the string of `_data6`'s first line did not end it: the declaration has the
    // closing `);` line too.
    let data6 = &fields(src)["_data6"];
    assert!(data6.ends_with(");"), "{data6}");
    assert!(data6.contains("'site;one'"), "{data6}");
}

#[test]
fn a_semicolon_inside_a_string_does_not_end_a_declaration() {
    let src = "\
final _d = f('a; b',
  'c',
);
final _e = 2;
";
    let d = fields(src);
    assert_eq!(d.keys().collect::<Vec<_>>(), ["_d", "_e"]);
    assert_eq!(d["_d"], "final _d = f('a; b', 'c', );");
}

#[test]
fn kept_fields_skips_consts_statics_locals_and_class_headers() {
    let src = "\
const _keep = _Keep();
final class X {
  final int y;
}
abstract final class AppRoutes {
  static const String _version = 'v';
  static List<RouteMatcher> _matchers = _allMatchers();
  static ShellKeys _keys = ShellKeys();
  static Widget notFound(Uri uri) {
    final router = GoRouter(
      routes: [],
    );
    return Text('x');
  }
}
void build() {
  final local = 1;
  print(local);
}
";
    assert!(fields(src).is_empty(), "{:?}", fields(src));
}

#[test]
fn a_multi_line_initializer_is_one_field() {
    let src = "final _d = f(\n  a,\n);\nfinal _after = 2;\n";
    let d = fields(src);
    assert_eq!(d.keys().collect::<Vec<_>>(), ["_after", "_d"]);
    assert_eq!(d["_d"], "final _d = f( a, );");
}

#[test]
fn prefixes_become_paths() {
    let mut imports: Vec<String> = (0..31).map(|i| format!("package:a/f{i}.dart")).collect();
    imports[3] = "package:app/three.dart".to_string();
    imports[30] = "package:app/thirty.dart".to_string();
    let src = "final _a = _i3.x;\nfinal _b = _i30.x;\nfinal _c = my_i3.x;\n";
    let d: BTreeMap<String, String> = kept_fields(src, &imports).into_iter().collect();
    assert_eq!(d["_a"], "final _a = package:app/three.dart.x;");
    assert_eq!(d["_b"], "final _b = package:app/thirty.dart.x;");
    // Not a prefix: a name it is part of.
    assert_eq!(d["_c"], "final _c = my_i3.x;");
    // A number the list does not have is left as it is.
    let short: BTreeMap<String, String> = kept_fields("final _e = _i9.x;\n", &imports[..2])
        .into_iter()
        .collect();
    assert_eq!(short["_e"], "final _e = _i9.x;");
}

#[test]
fn stamp_fills_both_slots_deterministically() {
    let src = "\
static const String _version = '/*version*/';
abstract final class AppRoutes {
  static const Map<String, String> _kept = {/*kept*/};
}
final _z = 1;
final _a = 2;
";
    let first = stamp(src, &[], "extraCodec=none");
    assert_eq!(first, stamp(src, &[], "extraCodec=none"));
    assert!(!first.contains("/*kept*/") && !first.contains("/*version*/"));

    let kept = kept_of(&first);
    assert_eq!(kept.keys().collect::<Vec<_>>(), ["(router)", "_a", "_z"]);
    assert!(kept.values().all(|h| h.len() == 8 && is_hex(h)), "{kept:?}");

    let version = version_of(&first);
    assert_eq!(version.len(), 16);
    assert!(is_hex(&version), "{version}");

    // The router's setting changes its own hash only.
    let other = stamp(src, &[], "extraCodec=_i1.extraCodec");
    let changed = kept_of(&other);
    assert_ne!(changed["(router)"], kept["(router)"]);
    assert_eq!(changed["_a"], kept["_a"]);
    assert_eq!(changed["_z"], kept["_z"]);
    assert_ne!(version_of(&other), version);
}

#[test]
fn appending_a_page_keeps_every_kept_hash() {
    let base: &[(&str, &str)] = &[
        ("page.dart", HOME),
        ("items/$id/data.dart", &data("int")),
        ("items/$id/page.dart", &item()),
    ];
    let zzz = page("Zzz");
    let mut more = base.to_vec();
    more.push(("zzz/page.dart", &zzz));
    let (before, _) = generated("", base);
    let (after, _) = generated("", &more);

    assert_ne!(version_of(&before), version_of(&after));
    let old = kept_of(&before);
    let new = kept_of(&after);
    assert!(!old.is_empty());
    for (name, hash) in &old {
        assert_eq!(new.get(name), Some(hash), "{name}");
    }
}

#[test]
fn inserting_a_route_before_a_data_route_changes_a_kept_hash() {
    let base: &[(&str, &str)] = &[
        ("page.dart", HOME),
        ("items/$id/data.dart", &data("int")),
        ("items/$id/page.dart", &item()),
    ];
    let aaa = page("Aaa");
    let mut more = base.to_vec();
    more.push(("aaa/page.dart", &aaa));
    let (before, _) = generated("", base);
    let (after, _) = generated("", &more);

    let old = kept_of(&before);
    let new = kept_of(&after);
    let changed: Vec<&String> = old
        .iter()
        .filter(|(name, hash)| new.get(*name).is_some_and(|h| h != *hash))
        .map(|(name, _)| name)
        .collect();
    assert!(
        !changed.is_empty(),
        "no kept name changed:\n{before}\n{after}"
    );
}

#[test]
fn extra_codec_changes_the_router_entry() {
    let (plain, _) = generated("", &[("page.dart", HOME)]);
    let (coded, _) = generated("", &[("page.dart", HOME), ("extra_codec.dart", CODEC)]);
    let old = kept_of(&plain);
    let new = kept_of(&coded);
    assert_eq!(
        old.keys().collect::<Vec<_>>(),
        new.keys().collect::<Vec<_>>()
    );
    for (name, hash) in &old {
        if name == "(router)" {
            assert_ne!(new[name], *hash);
        } else {
            assert_eq!(&new[name], hash, "{name}");
        }
    }
    has(&coded, &["extraCodec: _i", ".extraCodec,\n"]);
}

#[test]
fn the_router_builds_on_a_routing_config() {
    let (c, _) = generated("", &[("page.dart", HOME)]);
    has(
        &c,
        &[
            "final routing = _AppRoutesReload(_config(routes));",
            "final router = GoRouter.routingConfig(",
            "routingConfig: routing,",
            "routing.follow(router);",
            "errorBuilder: (context, state) => routing.notFound(state.uri),",
            "static RoutingConfig _config(List<RouteBase> routes) => RoutingConfig(",
            "final class _AppRoutesReload extends RoutesReload {",
        ],
    );
    assert!(!c.contains("final router = GoRouter(\n"), "{c}");
}

#[test]
fn shells_take_their_keys_from_the_mount() {
    let (c, _) = generated(
        "",
        &[
            ("(tabs)/layout.dart", TABS),
            ("(tabs)/a/page.dart", &page("A")),
            ("(tabs)/b/page.dart", &page("B")),
            ("dash/layout.dart", LAYOUT),
            ("dash/page.dart", &page("Dash")),
        ],
    );
    has(
        &c,
        &[
            "navigatorKey: _keys.navigator('layout:",
            "key: _keys.shell('layout:",
            "navigatorKey: _keys.navigator('tab:",
            "_keys = ShellKeys();",
            "static ShellKeys _keys = ShellKeys();",
        ],
    );
}

#[test]
fn the_reload_refreshes_matchers_manifest_devtools_observe() {
    let (c, _) = generated("", &[("page.dart", HOME), ("observe.dart", OBSERVE)]);
    let reload = section(
        &c,
        "static RoutingConfig _reload(GoRouter router) {",
        "\n  }\n",
    );
    has(
        reload,
        &[
            "_matchers = _allMatchers();",
            "devToolsRegister(",
            "observeAttach(router, _observeAt);",
            "return _config(_routes(_base));",
        ],
    );
    has(
        &c,
        &[
            "static List<RouteMatcher> _matchers = _allMatchers();",
            "static List<RouteMatcher> _allMatchers() => [",
            "static List<RouteBase> _routes(String at) {",
            "return _routes(at);",
        ],
    );

    let (plain, _) = generated("", &[("page.dart", HOME)]);
    let reload = section(
        &plain,
        "static RoutingConfig _reload(GoRouter router) {",
        "\n  }\n",
    );
    assert!(!reload.contains("observeAttach("), "{reload}");

    let (c, manifest) = generated(
        "fespalier:\n  output_manifest: lib/app.routes.g.dart\n",
        &[("page.dart", HOME)],
    );
    let getters = [
        "static Map<Type, RouteInfo<Object?>> get byType => routeIndex(all).byType;",
        "static Map<String, RouteInfo<Object?>> get byPath => routeIndex(all).byPath;",
    ];
    has(manifest.as_deref().unwrap(), &getters);
    assert!(!c.contains("static final Map<Type"), "{c}");

    let (c, manifest) = generated("", &[("page.dart", HOME)]);
    assert!(manifest.is_none());
    has(&c, &getters);
}
