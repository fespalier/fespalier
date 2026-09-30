//! Typed catch-alls: a `$$rest` that is a `List<int>`, `List<double>`, `List<num>`,
//! `List<bool>` or `List<DateTime>` instead of a `List<String>`. (The untyped catch-all
//! is tested in `paths_tests.rs`.)

use std::fs;

use crate::build;
use crate::config::Config;

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

/// Every diagnostic, rendered as the CLI prints its first line.
fn diags(files: &[(&str, &str)]) -> Vec<String> {
    let dir = project(files);
    let (_, diags, _) = build(&dir.path().join("lib/app"), &Config::default()).unwrap();
    diags.0.iter().map(|d| d.to_string()).collect()
}

fn errors(files: &[(&str, &str)]) -> Vec<String> {
    diags(files)
        .into_iter()
        .filter(|d| d.starts_with('✗'))
        .collect()
}

fn code(files: &[(&str, &str)]) -> String {
    let dir = project(files);
    let (code, diags, _) = build(&dir.path().join("lib/app"), &Config::default()).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    code
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

/// A page taking the catch-all `rest` as `ty`.
fn page(ty: &str) -> String {
    format!(
        "class RestPage extends StatelessWidget {{ const RestPage({{super.key, required this.rest}}); final {ty} rest; }}"
    )
}

/// The generated reader for each part type.
const READERS: [(&str, &str); 5] = [
    ("int", "Segment.asIntRest"),
    ("double", "Segment.asDoubleRest"),
    ("num", "Segment.asNumRest"),
    ("bool", "Segment.asBoolRest"),
    ("DateTime", "Segment.asDateTimeRest"),
];

#[test]
fn every_part_type_gets_its_reader_field_and_location() {
    for (item, reader) in READERS {
        let ty = format!("List<{item}>");
        let c = code(&[("docs/$$rest/page.dart", &page(&ty))]);
        has(
            &c,
            &[
                &format!(
                    "({{{ty} rest}}) _params2(GoRouterState s) => (rest: {reader}(s, 'rest'));"
                ),
                &format!("final {ty} rest;"),
                "const RestRoute({required this.rest});",
                // Each part encoded on its own, whatever its type.
                "return joinLocation(AppRoutes.base, '/docs${restPath(rest)}');",
                // A part that doesn't parse is not-found, like a bad `int` segment.
                "() => _params2(state),",
                "() => notFound(state.uri),",
            ],
        );
        lacks(&c, &["Segment.asRest("]);
    }
}

#[test]
fn a_list_of_strings_still_uses_the_plain_reader() {
    let c = code(&[("docs/$$rest/page.dart", &page("List<String>"))]);
    has(
        &c,
        &[
            "(rest: Segment.asRest(s, 'rest'))",
            "final List<String> rest;",
        ],
    );
    // An untyped one has nothing that can fail, so it doesn't parse before building.
    lacks(&c, &["asIntRest"]);
}

#[test]
fn an_optional_catch_all_can_be_typed_and_is_empty_when_absent() {
    let p = "class RestPage extends StatelessWidget { const RestPage({super.key, this.days = const []}); final List<DateTime> days; }";
    let c = code(&[("cal/$$$days/page.dart", p)]);
    has(
        &c,
        &[
            "const RestRoute({this.days = const []});",
            "final List<DateTime> days;",
            "//   /cal/*days?  RestRoute",
            "(days: Segment.asDateTimeRest(s, 'days'))",
            // The path without the catch-all is the same route.
            "path: joinLocation(at, '/cal')",
            "path: joinLocation(at, '/cal/:days(.+)')",
            // Nothing to assert on, since it may be empty.
            "String get location => joinLocation(AppRoutes.base, '/cal${restPath(days)}');",
        ],
    );
    lacks(&c, &["assert(days.isNotEmpty"]);
}

#[test]
fn a_required_catch_all_still_asserts_it_has_a_part() {
    let c = code(&[("docs/$$rest/page.dart", &page("List<int>"))]);
    has(
        &c,
        &["assert(rest.isNotEmpty, 'RestRoute needs at least one part in `rest`"],
    );
}

#[test]
fn files_must_agree_on_the_type() {
    let data = "Future<int> data(Ref ref, {required List<String> rest}) async => 1;";
    let e = errors(&[
        ("docs/$$rest/page.dart", &page("List<int>")),
        ("docs/$$rest/data.dart", data),
    ]);
    // Same shape as a segment's mismatch: the first file to say (data.dart is read first),
    // and the line the other one disagrees on.
    assert_eq!(
        e,
        [
            "✗ docs/$$rest/page.dart:1  `$rest` is List<String> in docs/$$rest/data.dart:1 but List<int> here"
        ]
    );

    // Untyped counts as List<String>: it can't be quietly widened by one file.
    let guard = "GuardResult guard(ProviderContainer c, {required List<num> rest}) => null;";
    let e = errors(&[
        ("docs/$$rest/page.dart", &page("List<int>")),
        ("docs/$$rest/guard.dart", guard),
    ]);
    assert!(
        e.iter()
            .any(|d| d
                .contains("`$rest` is List<int> in docs/$$rest/page.dart:1 but List<num> here")),
        "{e:?}"
    );

    let agree = "Future<int> data(Ref ref, {required List<int> rest}) async => 1;";
    assert!(
        errors(&[
            ("docs/$$rest/page.dart", &page("List<int>")),
            ("docs/$$rest/data.dart", agree)
        ])
        .is_empty()
    );
}

#[test]
fn a_mismatch_points_at_the_parameter_with_a_code_frame() {
    let dir = project(&[
        ("docs/$$rest/page.dart", &page("List<int>")),
        (
            "docs/$$rest/data.dart",
            "Future<int> data(Ref ref, {required List<bool> rest}) async => 1;",
        ),
    ]);
    let (_, diags, _) = build(&dir.path().join("lib/app"), &Config::default()).unwrap();
    let d = diags
        .0
        .iter()
        .find(|d| d.msg.contains("but List<") && d.msg.contains(" here"))
        .expect("a mismatch");
    // The span is the parameter's, which is what the renderer draws the code frame under.
    let span = d.span.as_ref().expect("a span for the code frame");
    let src = fs::read_to_string(dir.path().join("lib/app").join(&d.file)).unwrap();
    assert!(
        src[span.bytes.clone()].contains("rest"),
        "{:?}",
        &src[span.bytes.clone()]
    );
}

#[test]
fn other_element_types_are_rejected() {
    for ty in [
        "List<Object>",
        "List<int?>",
        "List<int>?",
        "List<List<int>>",
        "Iterable<int>",
        "Set<int>",
        "int",
        "String",
    ] {
        let e = errors(&[("docs/$$rest/page.dart", &page(ty))]);
        assert!(
            e.iter().any(|d| d.contains("a catch-all segment is the rest of the path, a `List` of String, int, double, num, bool or DateTime")),
            "{ty}: {e:?}"
        );
    }
}

#[test]
fn a_typed_catch_all_keys_data_by_its_path() {
    let data = "Future<int> data(Ref ref, {required List<int> rest}) async => rest.length;";
    let p = "class RestPage extends StatelessWidget { const RestPage({super.key, required this.rest, required this.data}); final List<int> rest; final int data; }";
    let c = code(&[
        ("docs/$$rest/page.dart", p),
        ("docs/$$rest/data.dart", data),
    ]);
    has(
        &c,
        &[
            // The key is one string; the list is parsed out of it again for data().
            "restKey(v.rest)",
            "final _data2 = FutureProvider.autoDispose.family(",
            "(Ref ref, String rest) => _i0.data(ref, rest: restParts(rest).map(int.parse).toList()),",
            // The typed helpers take the list itself.
            "static final watch = (WidgetRef ref, {required List<int> rest}) => ref.watch(data(restKey(rest)));",
        ],
    );
}

#[test]
fn each_part_type_is_read_back_from_a_data_key_with_its_own_parser() {
    for (item, parser) in [
        ("double", "double.parse"),
        ("num", "num.parse"),
        ("bool", "bool.parse"),
        ("DateTime", "DateTime.parse"),
    ] {
        let data = format!("Future<int> data(Ref ref, {{required List<{item}> rest}}) async => 1;");
        let p = format!(
            "class RestPage extends StatelessWidget {{ const RestPage({{super.key, required this.rest, required this.data}}); final List<{item}> rest; final int data; }}"
        );
        let c = code(&[
            ("docs/$$rest/page.dart", &p),
            ("docs/$$rest/data.dart", &data),
        ]);
        has(
            &c,
            &[&format!("rest: restParts(rest).map({parser}).toList()")],
        );
    }
    // A list of strings is what restParts already gives.
    let data = "Future<int> data(Ref ref, {required List<String> rest}) async => 1;";
    let p = "class RestPage extends StatelessWidget { const RestPage({super.key, required this.data}); final int data; }";
    let c = code(&[
        ("docs/$$rest/page.dart", p),
        ("docs/$$rest/data.dart", data),
    ]);
    has(&c, &["rest: restParts(rest))"]);
    lacks(&c, &[".map("]);
}

#[test]
fn a_provider_you_write_still_cant_be_keyed_by_a_catch_all() {
    let data = "final data = FutureProvider.family<int, List<int>>((ref, rest) async => 1);";
    let p = "class RestPage extends StatelessWidget { const RestPage({super.key, required this.rest}); final List<int> rest; }";
    let e = errors(&[
        ("docs/$$rest/page.dart", p),
        ("docs/$$rest/data.dart", data),
    ]);
    assert!(
        e.iter()
            .any(|m| m.contains("is a catch-all, a List that a provider can't be keyed by")),
        "{e:?}"
    );
}

#[test]
fn a_guard_takes_the_typed_list_too() {
    let guard = "GuardResult guard(ProviderContainer c, {required List<int> rest}) => null;";
    let c = code(&[
        ("docs/$$rest/page.dart", &page("List<int>")),
        ("docs/$$rest/guard.dart", guard),
    ]);
    has(
        &c,
        &["guardWithParams(", "(rest: Segment.asIntRest(s, 'rest'))"],
    );
    // A guard above the catch-all can't ask for it, as with any segment below the guard.
    let above = "GuardResult guard(ProviderContainer c, {required List<int> rest}) => null;";
    let e = errors(&[
        ("docs/guard.dart", above),
        ("docs/$$rest/page.dart", &page("List<int>")),
    ]);
    assert!(
        e.iter()
            .any(|d| d.contains("`rest` isn't a segment of this path")),
        "{e:?}"
    );
}

#[test]
fn a_redirect_shows_not_found_for_a_part_that_does_not_parse() {
    let r = "String redirect({required List<int> rest}) => '/';";
    let c = code(&[("old/$$rest/redirect.dart", r)]);
    has(
        &c,
        &[
            "(rest: Segment.asIntRest(s, 'rest'))",
            "builder: (context, state) => notFound(state.uri),",
        ],
    );
    // A list of strings can't fail to parse, so it needs no builder.
    let r = "String redirect({required List<String> rest}) => '/';";
    let c = code(&[("old/$$rest/redirect.dart", r)]);
    lacks(&c, &["builder:"]);
}

#[test]
fn the_manifest_and_route_table_name_the_list_type() {
    let dir = project(&[("docs/$$rest/page.dart", &page("List<int>"))]);
    let (c, _, _) = build(&dir.path().join("lib/app"), &Config::default()).unwrap();
    has(
        &c,
        &[
            "segments: [RouteParam('rest', 'List<int>', catchAll: true)],",
            "//   /docs/*rest  RestRoute",
        ],
    );
}

#[test]
fn a_typed_catch_all_still_sorts_after_its_siblings() {
    let c = code(&[
        ("docs/$$rest/page.dart", &page("List<int>")),
        (
            "docs/new/page.dart",
            "class NewPage extends StatelessWidget { const NewPage({super.key}); }",
        ),
    ]);
    let (new, rest) = (c.find("'/docs/new')"), c.find("(.+)"));
    assert!(new.is_some() && rest.is_some() && new < rest, "{c}");
}

#[test]
fn fsp_new_keeps_the_type_an_existing_catch_all_has() {
    let dir = project(&[("docs/$$rest/page.dart", &page("List<int>"))]);
    let args = crate::scaffold::NewArgs {
        route: "docs/[...rest]".into(),
        name: None,
        function: false,
        not_found: false,
        data: true,
        loading: false,
        error: false,
        layout: false,
        guard: false,
        transition: false,
    };
    crate::scaffold::new_route(dir.path(), &args).unwrap();
    let data = fs::read_to_string(dir.path().join("lib/app/docs/$$rest/data.dart")).unwrap();
    assert!(data.contains("required List<int> rest"), "{data}");
}
