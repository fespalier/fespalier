//! The hot reload's two const slots in the generated `app.g.dart` (since 0.19.0): `reload.rs` reads
//! the fields a reload keeps, and `emit.rs` stamps `_version` and `_kept`. The router and the
//! manifest the reload rebuilds are checked here too, against the same project as `match_tests.rs`.

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

use crate::action_tests::{code as built, errors};
use crate::config::Config;
use crate::reload::{Stamp, kept_fields, read_stamp, short_hash, stamp};
use crate::resolve::{folder_stem, section_name};
use crate::session::Session;
use crate::{analyze, gen_core, manifest};

const APP: &str = "class App extends StatelessWidget { const App({super.key, required this.router}); final GoRouter router; }";

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
fn a_static_final_in_a_mixin_or_an_extension_is_hashed_under_its_type() {
    let src = "\
mixin Plain {
  static final a = 1;
}
base mixin class Both {
  static final b = 2;
}
mixin Bound on Object {
  static final c = 3;
}
extension StringX<T> on List<T> {
  static final d = 4;
}
extension type Id(int v) {
  static final e = 5;
}
extension type const Key._(int v) {
  static final f = 6;
}
extension on int {
  static final g = 7;
}
extension<T> on List<T> {
  static final h = 8;
}
final extension = 9;
final mixinValue = 10;
class After {
  static final i = 11;
}
";
    let names: Vec<String> = kept_fields(src, &[]).into_iter().map(|(n, _)| n).collect();
    assert_eq!(
        names,
        [
            "Plain.a",
            "Both.b",
            "Bound.c",
            "StringX.d",
            "Id.e",
            "Key.f",
            "extension on int.g",
            "extension<T> on List<T>.h",
            "extension",
            "mixinValue",
            "After.i",
        ],
    );
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
fn inserting_a_route_before_a_data_route_keeps_every_kept_hash() {
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

    assert_ne!(version_of(&before), version_of(&after));
    let old = kept_of(&before);
    let new = kept_of(&after);
    assert!(old.contains_key("_dataItemsId"), "{old:?}");
    for (name, hash) in &old {
        assert_eq!(new.get(name), Some(hash), "{name}");
    }
}

/// The declarations a reload keeps, by name, each `_i<n>` import named by its path (as
/// `reload.rs` compares them). Since 0.20.0 the names of these declarations follow their folders.
fn declarations(code: &str) -> BTreeMap<String, String> {
    let mut imports: Vec<String> = Vec::new();
    for line in code.lines() {
        let Some(rest) = line.strip_prefix("import '") else {
            continue;
        };
        let Some((path, tail)) = rest.split_once('\'') else {
            continue;
        };
        let tail = tail.strip_prefix(" deferred").unwrap_or(tail);
        let Some(number) = tail.strip_prefix(" as _i") else {
            continue;
        };
        let n: usize = number
            .chars()
            .take_while(char::is_ascii_digit)
            .collect::<String>()
            .parse()
            .unwrap();
        if imports.len() <= n {
            imports.resize(n + 1, String::new());
        }
        imports[n] = path.to_string();
    }
    kept_fields(code, &imports).into_iter().collect()
}

/// The first name a declaration spells by position (since 0.20.0 none is kept): `_data`, `_lib`,
/// `_optimistic` or `_action`, or a DevTools site (`'d`, `'a`), followed by a digit.
fn spells_a_number(decl: &str) -> Option<String> {
    for prefix in ["_data", "_lib", "_optimistic", "_action", "'d", "'a"] {
        for (at, _) in decl.match_indices(prefix) {
            if decl[at + prefix.len()..].starts_with(|c: char| c.is_ascii_digit()) {
                return Some(decl[at..].chars().take(24).collect());
            }
        }
    }
    None
}

const AAA: &str = "class AaaPage extends StatelessWidget { const AaaPage({super.key}); }";

const MID: &str = "class MidPage extends StatelessWidget { const MidPage({super.key}); }";

const AAB: &str = "class AabPage extends StatelessWidget { const AabPage({super.key, required this.data}); final int data; }";

const AAB_DATA: &str = "Future<int> data(Ref ref) async => 0;";

const YAK: &str = "class YakPage extends StatelessWidget { const YakPage({super.key}); }";

const DEFERRED: &str = "const deferred = true;\n";

/// Every kind of name a route with a data.dart, an action.dart, a section layout and a deferred
/// page gives the generated file (since 0.20.0 each follows its folder).
const RICH: &[(&str, &str)] = &[
    ("page.dart", HOME),
    (
        "items/$id/page.dart",
        "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.data}); final int data; }",
    ),
    (
        "items/$id/data.dart",
        "Future<int> data(Ref ref, {required int id}) async => 0;",
    ),
    (
        "items/$id/action.dart",
        "import 'package:m/m.dart' as m;\nint optimistic(int current, String input) => current;\nFuture<void> action(Ref ref, {required int id, required String input}) async {}\nFuture<void> rename(Ref ref, {required int id, required m.Item input}) async {}\n",
    ),
    (
        "teams/$teamId/layout.dart",
        "class TeamLayout extends StatelessWidget { const TeamLayout({super.key, required this.data, required this.child}); final String data; final Widget child; }",
    ),
    (
        "teams/$teamId/data.dart",
        "Future<String> data(Ref ref, {required String teamId}) async => '';",
    ),
    (
        "teams/$teamId/action.dart",
        "Future<void> addMember(Ref ref, {required String teamId, required String input}) async {}\n",
    ),
    (
        "teams/$teamId/members/page.dart",
        "class MembersPage extends StatelessWidget { const MembersPage({super.key}); }",
    ),
    (
        "big/page.dart",
        "class BigPage extends StatelessWidget { const BigPage({super.key}); }",
    ),
    ("big/route.dart", DEFERRED),
    (
        "zoo/page.dart",
        "class ZooPage extends StatelessWidget { const ZooPage({super.key}); }",
    ),
    ("zoo/route.dart", DEFERRED),
];

#[test]
fn the_names_a_reload_keeps_follow_the_folders() {
    let c = built(RICH);
    has(
        &c,
        &[
            "final _dataItemsId = ",
            "final _optimisticItemsId = ",
            "final _actionItemsId_action = ",
            "final _actionItemsId_rename = ",
            "final _dataTeamsTeamId = ",
            "final _actionTeamsTeamId_addMember = ",
            "final _libBig = ",
            "final _libZoo = ",
            "static List<DeferredLibrary> _allDeferred() => [_libBig, _libZoo];",
            "static List<DeferredLibrary> get deferred => _deferred;",
            "import 'app/big/page.dart' deferred as _pageBig;",
            "final _libBig = DeferredLibrary(_pageBig.loadLibrary, 'big/page.dart');",
            "traceData(ref, 'dItemsId', id, ",
            "site: 'aItemsId_action',",
            "site: 'aTeamsTeamId_addMember',",
            "import 'package:m/m.dart' as _e19a273a4_m;",
            "_e19a273a4_m.Item input",
        ],
    );
    assert!(
        !c.contains("deferred as _i"),
        "a deferred page is named after its folder"
    );
    for (name, decl) in declarations(&c) {
        assert!(
            spells_a_number(&decl).is_none(),
            "{name} spells a position: {decl}"
        );
    }
}

/// Builds [base], then [base] with each of [cases] added (a name for the message, and the files),
/// and asserts that every declaration a reload keeps, and every hash in `_kept`, is as it was.
fn adding_files_keeps_every_kept_declaration(
    base: &[(&str, &str)],
    cases: &[(&str, Vec<(&str, &str)>)],
) {
    adding_files_keeps_every_kept_declaration_with(base, cases, built);
}

/// [adding_files_keeps_every_kept_declaration] for a project that `build` makes (since 0.20.0 a
/// test can give the config a `deferred: true`).
fn adding_files_keeps_every_kept_declaration_with(
    base: &[(&str, &str)],
    cases: &[(&str, Vec<(&str, &str)>)],
    build: impl Fn(&[(&str, &str)]) -> String,
) {
    let before = build(base);
    let old = declarations(&before);
    let old_hashes = kept_of(&before);
    assert!(!old.is_empty() && !old_hashes.is_empty());
    for (file, extra) in cases {
        let mut files = base.to_vec();
        files.extend(extra.iter().copied());
        let after = build(&files);
        let new = declarations(&after);
        for (name, decl) in &old {
            assert_eq!(
                new.get(name),
                Some(decl),
                "{name} changed when {file} was added"
            );
        }
        let new_hashes = kept_of(&after);
        for (name, hash) in &old_hashes {
            assert_eq!(
                new_hashes.get(name),
                Some(hash),
                "{name} changed when {file} was added"
            );
        }
    }
}

#[test]
fn a_route_added_anywhere_leaves_every_other_kept_declaration_as_it_was() {
    adding_files_keeps_every_kept_declaration(
        RICH,
        &[
            ("aaa/page.dart", vec![("aaa/page.dart", AAA)]),
            ("(g)/mid/page.dart", vec![("(g)/mid/page.dart", MID)]),
            (
                "items/$id/aaa/page.dart",
                vec![("items/$id/aaa/page.dart", AAA)],
            ),
            (
                "teams/$teamId/aaa/page.dart",
                vec![("teams/$teamId/aaa/page.dart", AAA)],
            ),
            (
                "aab/page.dart",
                vec![("aab/page.dart", AAB), ("aab/data.dart", AAB_DATA)],
            ),
        ],
    );
}

/// An enum in a library outside the app folder, which a segment names through a prefixed import.
const CATEGORY_ENUM: (&str, &str) = ("../models/category.dart", "enum Category { shoes, hats }\n");

/// `shop/$category/b/` has a page and a data.dart that both type the segment `m.Category`.
const B_PAGE: &str = "import '../../../../models/category.dart' as m;\nclass BPage extends StatelessWidget { const BPage({super.key, required this.category, required this.data}); final m.Category category; final int data; }";

const B_DATA: &str = "import '../../../../models/category.dart' as m;\nFuture<int> data(Ref ref, {required m.Category category}) async => 0;";

/// A sibling page that types the same segment through the same import.
const A_PAGE: &str = "import '../../../../models/category.dart' as m;\nclass APage extends StatelessWidget { const APage({super.key, required this.category}); final m.Category category; }";

/// A guard of the segment, one folder up, that names the library through its own relative path.
const CATEGORY_GUARD: &str = "import '../../../models/category.dart' as m;\nString? guard(Ref ref, {required m.Category category}) => null;\n";

/// The project of the two tests below: a data route under a segment that names an enum.
const CATEGORY_BASE: [(&str, &str); 4] = [
    ("page.dart", HOME),
    ("shop/$category/b/page.dart", B_PAGE),
    ("shop/$category/b/data.dart", B_DATA),
    CATEGORY_ENUM,
];

// The first file that types a segment names its type for every route below it. An alias made of
// that file's path changed when another file became the first: a sibling page that sorts earlier,
// or a guard of the segment's folder. The alias is made of the library, so it does not.

#[test]
fn a_sibling_that_types_a_segment_first_leaves_the_alias_of_a_kept_type() {
    let c = built(&CATEGORY_BASE);
    assert!(c.contains("final _dataShopCategoryB = "), "{c}");
    adding_files_keeps_every_kept_declaration(
        &CATEGORY_BASE,
        &[(
            "shop/$category/a/page.dart",
            vec![("shop/$category/a/page.dart", A_PAGE)],
        )],
    );
}

#[test]
fn a_guard_that_types_a_segment_first_leaves_the_alias_of_a_kept_type() {
    adding_files_keeps_every_kept_declaration(
        &CATEGORY_BASE,
        &[(
            "shop/$category/guard.dart",
            vec![("shop/$category/guard.dart", CATEGORY_GUARD)],
        )],
    );
}

#[test]
fn an_import_repointed_at_another_library_changes_what_a_reload_keeps() {
    // The action's input is `m.Item` in both, but from another library: the app that holds the old
    // one must restart, and the hash says so. (Before 0.20.0 no kept hash saw the library.)
    let notes = |lib: &str| {
        format!(
            "import 'package:demo/{lib}' as m;\nFuture<void> rename(Ref ref, {{required m.Item input}}) async {{}}\n"
        )
    };
    let build = |lib: &str| {
        let action = notes(lib);
        built(&[
            ("page.dart", HOME),
            ("notes/page.dart", &page("Notes")),
            ("notes/action.dart", &action),
        ])
    };
    let (a, b, again) = (build("a.dart"), build("b.dart"), build("a.dart"));
    assert_eq!(kept_of(&a), kept_of(&again));
    let (old, new) = (kept_of(&a), kept_of(&b));
    assert!(old.contains_key("_actionNotes_rename"), "{old:?}");
    for name in ["_actionNotes_rename", "NotesRoute.rename"] {
        assert_ne!(old.get(name), new.get(name), "{name}");
    }
    assert_ne!(version_of(&a), version_of(&b));
}

#[test]
fn folders_whose_stems_meet_each_take_a_hash_of_their_own_path() {
    const HISTORY_A: &str = "class HistoryAPage extends StatelessWidget { const HistoryAPage({super.key, required this.data}); final int data; }";
    const HISTORY_B: &str =
        "class HistoryBPage extends StatelessWidget { const HistoryBPage({super.key}); }";
    const HISTORY_DATA: &str = "Future<int> data(Ref ref) async => 0;";
    let both = [
        ("page.dart", HOME),
        ("order-history/page.dart", HISTORY_A),
        ("order-history/data.dart", HISTORY_DATA),
        ("order_history/page.dart", HISTORY_B),
        ("order_history/data.dart", HISTORY_DATA),
    ];
    let c = built(&both);
    has(
        &c,
        &[
            "final _dataOrderHistory_a6adc020 = ",
            "final _dataOrderHistory_5cefc874 = ",
            "traceData(ref, 'dOrderHistory_a6adc020', null, ",
        ],
    );
    assert!(!c.contains("final _dataOrderHistory = "), "{c}");
    // A route added elsewhere keeps both names.
    let mut more = both.to_vec();
    more.push(("aaa/page.dart", AAA));
    let c = built(&more);
    has(
        &c,
        &[
            "final _dataOrderHistory_a6adc020 = ",
            "final _dataOrderHistory_5cefc874 = ",
        ],
    );
    // Without its data.dart, order_history names nothing, so order-history keeps the plain stem.
    let alone = [
        ("page.dart", HOME),
        ("order-history/page.dart", HISTORY_A),
        ("order-history/data.dart", HISTORY_DATA),
        ("order_history/page.dart", HISTORY_B),
    ];
    let c = built(&alone);
    has(&c, &["final _dataOrderHistory = "]);
    assert!(!c.contains("_dataOrderHistory_a6adc020"), "{c}");
}

#[test]
fn two_folders_whose_hashes_agree_are_an_error_and_not_a_name_declared_twice() {
    // Found by searching: two spellings of one stem whose paths agree on all 8 digits of the hash.
    const ONE: &str = "a_b-c.d.e_f-g-h.i.j.k-l-m-n";
    const TWO: &str = "a_b_c_d-e-f.g-h-i-j_k_l-m-n";
    assert_eq!(folder_stem(ONE), folder_stem(TWO));
    assert_eq!(short_hash(ONE), short_hash(TWO));
    let page = |name: &str| {
        format!(
            "class {name}Page extends StatelessWidget {{ const {name}Page({{super.key, required this.data}}); final int data; }}"
        )
    };
    let (one_page, two_page) = (page("One"), page("Two"));
    let (one, one_data) = (format!("{ONE}/page.dart"), format!("{ONE}/data.dart"));
    let (two, two_data) = (format!("{TWO}/page.dart"), format!("{TWO}/data.dart"));
    let files = |with_both: bool| {
        let mut files = vec![
            ("page.dart", HOME),
            (one.as_str(), one_page.as_str()),
            (one_data.as_str(), "Future<int> data(Ref ref) async => 0;"),
        ];
        if with_both {
            files.push((two.as_str(), two_page.as_str()));
            files.push((two_data.as_str(), "Future<int> data(Ref ref) async => 0;"));
        }
        errors(&files)
    };
    assert_eq!(files(false), "");
    let e = files(true);
    assert!(
        e.contains(&format!("✗ {TWO}/data.dart"))
            && e.contains(&format!(
                "the folders `{ONE}` and `{TWO}` would both be called `ABCDEFGHIJKLMN_ff92c64a`"
            )),
        "{e}"
    );
}

#[test]
fn a_folder_stem_is_its_path_in_pascal_case() {
    for (dir, stem) in [
        ("", "Root"),
        ("products/$id", "ProductsId"),
        ("(tabs)/(home)", "TabsHome"),
        ("browse/$$categories", "BrowseCategories"),
        ("wiki/$$$path", "WikiPath"),
        ("order-history", "OrderHistory"),
        ("order_history", "OrderHistory"),
        ("teams/$teamId", "TeamsTeamId"),
        ("2024/recap", "Path2024Recap"),
        ("class", "Class"),
    ] {
        assert_eq!(folder_stem(dir), stem, "{dir:?}");
    }
    assert_eq!(section_name("(shop)"), "ShopSection");
    assert_eq!(section_name(""), "RootSection");
}

#[test]
fn a_deferred_route_added_anywhere_keeps_every_kept_hash() {
    // Since 0.20.0 `AppRoutes.deferred` is a getter over `_deferred`, which a reload makes again, so
    // no kept declaration spells the list and a deferred route added anywhere keeps every hash.
    adding_files_keeps_every_kept_declaration(
        RICH,
        &[
            (
                "aaa/page.dart",
                vec![("aaa/page.dart", AAA), ("aaa/route.dart", DEFERRED)],
            ),
            (
                "yak/page.dart",
                vec![("yak/page.dart", YAK), ("yak/route.dart", DEFERRED)],
            ),
            (
                "items/$id/aaa/page.dart",
                vec![
                    ("items/$id/aaa/page.dart", AAA),
                    ("items/$id/aaa/route.dart", DEFERRED),
                ],
            ),
            (
                "aab/page.dart",
                vec![
                    ("aab/page.dart", AAB),
                    ("aab/data.dart", AAB_DATA),
                    ("aab/route.dart", DEFERRED),
                ],
            ),
        ],
    );
    assert!(!kept_of(&built(RICH)).contains_key("AppRoutes.deferred"));
}

#[test]
fn with_deferred_true_a_page_added_anywhere_keeps_every_kept_hash() {
    let base: &[(&str, &str)] = &[
        ("page.dart", HOME),
        ("items/$id/page.dart", &item()),
        ("items/$id/data.dart", &data("int")),
        ("big/page.dart", &page("Big")),
    ];
    let yaml = "fespalier:\n  deferred: true\n";
    let (before, _) = generated(yaml, base);
    has(
        &before,
        &[
            "import 'app/page.dart' deferred as _pageRoot;",
            "import 'app/big/page.dart' deferred as _pageBig;",
        ],
    );
    let zzz = page("Zzz");
    adding_files_keeps_every_kept_declaration_with(
        base,
        &[
            ("aaa/page.dart", vec![("aaa/page.dart", AAA)]),
            ("(g)/mid/page.dart", vec![("(g)/mid/page.dart", MID)]),
            (
                "items/$id/aaa/page.dart",
                vec![("items/$id/aaa/page.dart", AAA)],
            ),
            ("zzz/page.dart", vec![("zzz/page.dart", zzz.as_str())]),
        ],
        |files| generated(yaml, files).0,
    );
    let mut more = base.to_vec();
    more.push(("aaa/page.dart", AAA));
    let (after, _) = generated(yaml, &more);
    has(
        &after,
        &[
            "import 'app/big/page.dart' deferred as _pageBig;",
            "import 'app/aaa/page.dart' deferred as _pageAaa;",
        ],
    );
}

#[test]
fn turning_deferred_on_or_off_keeps_every_other_kept_hash() {
    let base: &[(&str, &str)] = &[
        ("page.dart", HOME),
        ("big/page.dart", &page("Big")),
        ("big/route.dart", DEFERRED),
        ("items/$id/page.dart", &item()),
        ("items/$id/data.dart", &data("int")),
    ];
    let mut more = base.to_vec();
    more.push(("items/$id/route.dart", DEFERRED));
    let (before, _) = generated("", base);
    let (after, _) = generated("", &more);
    let old = kept_of(&before);
    let new = kept_of(&after);
    // On: every name the old map has keeps its hash, and the one new name is the page's library.
    for (name, hash) in &old {
        assert_eq!(new.get(name), Some(hash), "{name}");
    }
    assert!(new.contains_key("_libItemsId") && !old.contains_key("_libItemsId"));
    // Off: the same two maps the other way round, so every name both have is equal.
    for (name, hash) in &new {
        if let Some(was) = old.get(name) {
            assert_eq!(was, hash, "{name}");
        }
    }
    has(
        &after,
        &["import 'app/items/\\$id/page.dart' deferred as _pageItemsId;"],
    );
}

#[test]
fn a_deferred_page_is_imported_under_its_folder_so_a_route_put_before_it_renames_nothing() {
    // The VM and DDC keep a deferred import's loaded state under its prefix's name across a hot
    // reload (`_pageCheckout`, not `_i7`), so a route put before it must not renumber it.
    let products = "class ProductPage extends StatelessWidget { const ProductPage({super.key, required this.data}); final int data; }";
    let base: &[(&str, &str)] = &[
        ("page.dart", HOME),
        ("checkout/page.dart", &page("Checkout")),
        ("checkout/route.dart", DEFERRED),
        ("products/$id/page.dart", products),
        ("products/$id/data.dart", &data("int")),
        ("products/$id/route.dart", DEFERRED),
    ];
    let about = page("About");
    let mut more = base.to_vec();
    more.push(("about/page.dart", &about));
    let before = generated("", base).0;
    let after = generated("", &more).0;
    let lines = |c: &str| {
        c.lines()
            .filter(|l| l.contains(" deferred as "))
            .map(str::to_string)
            .collect::<Vec<_>>()
    };
    assert_eq!(
        lines(&before),
        [
            "import 'app/checkout/page.dart' deferred as _pageCheckout;",
            "import 'app/products/\\$id/page.dart' deferred as _pageProductsId;",
        ]
    );
    assert_eq!(lines(&before), lines(&after));
    has(
        &before,
        &[
            "final _libCheckout = DeferredLibrary(_pageCheckout.loadLibrary, 'checkout/page.dart');",
            "_pageCheckout.CheckoutPage()",
            "_pageProductsId.ProductPage(",
        ],
    );
    assert!(!before.contains("deferred as _i"));
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
    assert!(!reload.contains("DeferredLibrary.register("), "{reload}");

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

#[test]
fn the_reload_lists_and_registers_the_deferred_libraries_again() {
    // A swap that adds an app's first deferred route must reach `loadDeferred()` and
    // `DeferredLibrary.anyPending`, which only `mount()` registered before.
    let (c, _) = generated(
        "",
        &[
            ("page.dart", HOME),
            ("big/page.dart", &page("Big")),
            ("big/route.dart", "const deferred = true;\n"),
        ],
    );
    let reload = section(
        &c,
        "static RoutingConfig _reload(GoRouter router) {",
        "\n  }\n",
    );
    has(
        reload,
        &[
            "_deferred = _allDeferred();",
            "DeferredLibrary.register(deferred);",
        ],
    );
    let listed = reload.find("_deferred = _allDeferred();").unwrap();
    assert!(listed < reload.find("DeferredLibrary.register(deferred);").unwrap());
    let mount = section(&c, "static List<RouteBase> mount({", "return _routes(at);");
    has(mount, &["DeferredLibrary.register(deferred);"]);

    // And that swap is not refused: the first deferred route adds names, it changes none.
    let (before, _) = generated("", &[("page.dart", HOME), ("big/page.dart", &page("Big"))]);
    let old = kept_of(&before);
    let new = kept_of(&c);
    assert!(!old.contains_key("AppRoutes.deferred"), "{old:?}");
    assert!(!new.contains_key("AppRoutes.deferred"), "{new:?}");
    assert!(new.contains_key("_libBig"), "{new:?}");
    for (name, hash) in &old {
        assert_eq!(new.get(name), Some(hash), "{name}");
    }
}

// --- the stamp `fsp dev` reads back (since 0.19.0) ---------------------------------------------

/// A stamp with these kept names and hashes.
fn st(kept: &[(&str, &str)]) -> Stamp {
    Stamp {
        version: "0123456789abcdef".into(),
        kept: kept
            .iter()
            .map(|(name, hash)| ((*name).to_string(), (*hash).to_string()))
            .collect(),
    }
}

/// One regeneration of the project at `dir`, as `fsp dev`'s watch runs it: `session` keeps what
/// the last one left. Returns whether it wrote the output.
fn regenerate(dir: &Path, session: &mut Session) -> bool {
    let cfg = Config::load(dir).unwrap();
    gen_core(dir, &cfg, true, session, |_, _| {}).unwrap().wrote
}

#[test]
fn read_stamp_reads_what_stamp_wrote() {
    let (code, _) = generated(
        "",
        &[
            ("page.dart", HOME),
            ("items/$id/data.dart", &data("int")),
            ("items/$id/page.dart", &item()),
        ],
    );
    let read = read_stamp(&code).expect("a stamp");
    assert_eq!(read.version, version_of(&code));
    assert_eq!(read.kept, kept_of(&code));
}

#[test]
fn read_stamp_reads_a_formatted_file() {
    // What `dart format` leaves: the version on the line after its `=`, a one-line map, and a name
    // with a `$` that `dart_str` escaped.
    let formatted = "  static const String _version =\n      '0123456789abcdef';\n  static const Map<String, String> _kept = {'(router)': '0123abcd', 'A.\\$b': 'fedcba98'};\n";
    let read = read_stamp(formatted).expect("a stamp");
    assert_eq!(read.version, "0123456789abcdef");
    assert_eq!(
        read.kept.get("(router)").map(String::as_str),
        Some("0123abcd")
    );
    assert_eq!(read.kept.get("A.$b").map(String::as_str), Some("fedcba98"));
}

#[test]
fn read_stamp_reads_every_example() {
    let examples = Path::new(env!("CARGO_MANIFEST_DIR")).join("../examples");
    let mut read = 0;
    for entry in fs::read_dir(&examples).unwrap() {
        let file = entry.unwrap().path().join("lib/app.g.dart");
        let Ok(text) = fs::read_to_string(&file) else {
            continue;
        };
        let stamp = read_stamp(&text).unwrap_or_else(|| panic!("no stamp in {}", file.display()));
        assert!(stamp.kept.contains_key("(router)"), "{}", file.display());
        read += 1;
    }
    assert!(read >= 10, "only {read} examples were read");
}

#[test]
fn read_stamp_is_none_without_a_stamp() {
    assert_eq!(read_stamp(""), None);
    // The template's own slots, which `stamp` fills.
    assert_eq!(
        read_stamp(
            "static const String _version = '/*version*/';\nstatic const Map<String, String> _kept = {/*kept*/};"
        ),
        None
    );
    // A version of 15 digits.
    assert_eq!(
        read_stamp(
            "static const String _version = '0123456789abcde';\nstatic const Map<String, String> _kept = {'(router)': '0123abcd'};"
        ),
        None
    );
    // A hash that is not hex.
    assert_eq!(
        read_stamp(
            "static const String _version = '0123456789abcdef';\nstatic const Map<String, String> _kept = {'(router)': '0123abcg'};"
        ),
        None
    );
    // An odd number of literals: a name with no hash.
    assert_eq!(
        read_stamp(
            "static const String _version = '0123456789abcdef';\nstatic const Map<String, String> _kept = {'(router)': '0123abcd', 'a.b'};"
        ),
        None
    );
    // A version and no kept field at all: never what `stamp` writes, which always keeps `(router)`.
    assert_eq!(
        read_stamp(
            "static const String _version = '0123456789abcdef';\nstatic const Map<String, String> _kept = {/*kept*/};"
        ),
        None
    );
}

#[test]
fn swaps_to_is_the_rule_of_routes_reload() {
    let old = st(&[("a", "11111111"), ("b", "22222222")]);
    assert!(old.swaps_to(&old), "the same routes swap");
    assert!(
        old.swaps_to(&st(&[
            ("a", "11111111"),
            ("b", "22222222"),
            ("c", "33333333")
        ])),
        "an added name swaps"
    );
    assert!(
        old.swaps_to(&st(&[("a", "11111111")])),
        "a removed name swaps"
    );
    assert!(
        !old.swaps_to(&st(&[("a", "11111111"), ("b", "99999999")])),
        "a changed hash does not swap"
    );
    assert!(st(&[]).swaps_to(&old), "an empty baseline swaps");
}

#[test]
fn a_pass_says_what_fsp_dev_needs() {
    let dir = project(
        "",
        &[
            ("page.dart", HOME),
            ("app.dart", APP),
            ("items/$id/data.dart", &data("int")),
            ("items/$id/page.dart", &item()),
        ],
    );
    let mut session = Session::default();
    // The first pass writes the output and the main, and the main is what `fsp dev` restarts for.
    assert!(regenerate(dir.path(), &mut session));
    assert!(session.wrote && session.main_changed && session.swaps);
    let disk = fs::read_to_string(dir.path().join("lib/app.g.dart")).unwrap();
    let first = session.stamp.clone().expect("a stamp");
    assert_eq!(Some(first.clone()), read_stamp(&disk));
    // Nothing changed: nothing is written, and the stamp is the same.
    assert!(!regenerate(dir.path(), &mut session));
    assert!(!session.wrote && !session.main_changed);
    assert_eq!(session.stamp.as_ref(), Some(&first));
    // A page that sorts last adds names and changes none: the routes swap.
    fs::create_dir_all(dir.path().join("lib/app/zzz")).unwrap();
    fs::write(dir.path().join("lib/app/zzz/page.dart"), page("Zzz")).unwrap();
    assert!(regenerate(dir.path(), &mut session));
    assert!(session.wrote && !session.main_changed);
    let second = session.stamp.clone().expect("a stamp");
    assert_ne!(second.version, first.version);
    assert!(first.swaps_to(&second));
    // A page that sorts first renames nothing (since 0.20.0): the routes swap.
    fs::create_dir_all(dir.path().join("lib/app/aaa")).unwrap();
    fs::write(dir.path().join("lib/app/aaa/page.dart"), page("Aaa")).unwrap();
    assert!(regenerate(dir.path(), &mut session));
    let third = session.stamp.clone().expect("a stamp");
    assert!(second.swaps_to(&third), "a page that sorts first swaps");
    // The first deferred route rewrites the main: the main loads the code before the first frame.
    fs::create_dir_all(dir.path().join("lib/app/big")).unwrap();
    fs::write(dir.path().join("lib/app/big/page.dart"), page("Big")).unwrap();
    fs::write(dir.path().join("lib/app/big/route.dart"), DEFERRED).unwrap();
    assert!(regenerate(dir.path(), &mut session));
    assert!(
        session.main_changed,
        "the first deferred route rewrites the main"
    );
    let big = session.stamp.clone().expect("a stamp");
    // A second deferred route swaps (since 0.20.0), and so does its removal.
    fs::create_dir_all(dir.path().join("lib/app/zoo")).unwrap();
    fs::write(dir.path().join("lib/app/zoo/page.dart"), page("Zoo")).unwrap();
    fs::write(dir.path().join("lib/app/zoo/route.dart"), DEFERRED).unwrap();
    assert!(regenerate(dir.path(), &mut session));
    assert!(
        !session.main_changed,
        "a second deferred route leaves the main alone"
    );
    let zoo = session.stamp.clone().expect("a stamp");
    assert!(
        big.swaps_to(&zoo),
        "a second deferred route swaps (since 0.20.0)"
    );
    fs::remove_dir_all(dir.path().join("lib/app/zoo")).unwrap();
    assert!(regenerate(dir.path(), &mut session));
    assert!(!session.main_changed);
    let gone = session.stamp.clone().expect("a stamp");
    assert!(
        zoo.swaps_to(&gone),
        "a removed deferred route swaps (since 0.20.0)"
    );
    // A data() that becomes a stream changes a provider the reload keeps: a restart.
    fs::write(
        dir.path().join("lib/app/items/$id/data.dart"),
        "Stream<int> data(Ref ref, {required int id}) async* { yield id; }",
    )
    .unwrap();
    assert!(regenerate(dir.path(), &mut session));
    let fourth = session.stamp.clone().expect("a stamp");
    assert!(!gone.swaps_to(&fourth));
    // startup.dart is read by the generated main, so the main is written again.
    fs::write(dir.path().join("lib/app/startup.dart"), "void startup() {}").unwrap();
    assert!(regenerate(dir.path(), &mut session));
    assert!(session.main_changed);
}

#[test]
fn a_pass_that_stops_on_an_error_reports_nothing_written() {
    let dir = project(
        "",
        &[
            ("page.dart", HOME),
            ("app.dart", APP),
            ("items/$id/data.dart", &data("int")),
            ("items/$id/page.dart", &item()),
        ],
    );
    let mut session = Session::default();
    assert!(
        regenerate(dir.path(), &mut session),
        "the first pass writes"
    );
    // Two public widgets in one file: the generator stops on it, and writes nothing.
    fs::create_dir_all(dir.path().join("lib/app/bad")).unwrap();
    fs::write(
        dir.path().join("lib/app/bad/page.dart"),
        format!("{}\n{}", page("One"), page("Two")),
    )
    .unwrap();
    let cfg = Config::load(dir.path()).unwrap();
    assert!(gen_core(dir.path(), &cfg, true, &mut session, |_, _| {}).is_err());
    assert!(!session.wrote, "the failed pass wrote nothing");
    assert!(!session.main_changed);
    assert!(session.stamp.is_none());
}
