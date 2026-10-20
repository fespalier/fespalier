//! A failed guard's view (since 0.21.0): every redirect runs through `runRedirect`, the router's
//! error route is `AppRoutes.errorPage`, and a route whose guard or `redirect.dart` can fail gets
//! the nearest error.dart as its `guardError` when that file takes only the error, its stack trace
//! and a retry. The generated code is checked as text, and the routes JSON is unchanged.

use std::fs;

use crate::config::Config;
use crate::reload::read_stamp;
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

fn code_with(cfg: &Config, files: &[(&str, &str)]) -> String {
    let dir = project(files);
    let (code, diags, _) = build(&dir.path().join("lib/app"), cfg).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    code
}

fn code(files: &[(&str, &str)]) -> String {
    code_with(&Config::default(), files)
}

/// Whether the code has each snippet, whatever its indentation.
fn has(code: &str, needles: &[&str]) {
    let flat = |s: &str| s.split_whitespace().collect::<Vec<_>>().join(" ");
    let code_flat = flat(code);
    for n in needles {
        assert!(code_flat.contains(&flat(n)), "missing `{n}` in:\n{code}");
    }
}

fn lacks(code: &str, needles: &[&str]) {
    for n in needles {
        assert!(!code.contains(n), "unexpected `{n}` in:\n{code}");
    }
}

fn count(code: &str, needle: &str) -> usize {
    code.matches(needle).count()
}

/// The `RouteMatcher` of the route at `pattern` (`['checkout']`), up to the next one.
fn matcher<'c>(code: &'c str, pattern: &str) -> &'c str {
    let start = code
        .find(&format!("RouteMatcher({pattern}"))
        .unwrap_or_else(|| panic!("no matcher {pattern} in:\n{code}"));
    let end = code[start + 1..]
        .find("RouteMatcher(")
        .map_or(code.len(), |i| start + 1 + i);
    &code[start..end]
}

fn page(name: &str) -> String {
    format!("class {name}Page extends StatelessWidget {{ const {name}Page({{super.key}}); }}")
}

const REF_GUARD: &str = "GuardResult guard(Ref ref) => null;";
const CONTAINER_GUARD: &str = "GuardResult guard(ProviderContainer c) => null;";
const ROOT_ERROR: &str = "class RootError extends StatelessWidget { const RootError({super.key, required Object error, required VoidCallback retry}); }";

#[test]
fn every_redirect_runs_through_run_redirect() {
    let c = code(&[
        ("(members)/guard.dart", REF_GUARD),
        (
            "(members)/old/redirect.dart",
            "String redirect() => '/inbox';",
        ),
        ("(members)/inbox/page.dart", &page("Inbox")),
        ("account/guard.dart", CONTAINER_GUARD),
        ("account/page.dart", &page("Account")),
        (
            "docs/redirect.dart",
            "String redirect(Ref ref) => '/inbox';",
        ),
    ]);
    // A Ref guard, a ProviderContainer guard, a chain and a redirect.dart are each inside it.
    has(
        &c,
        &[
            "redirect: (context, state) => runRedirect(() => firstRedirect([",
            "redirect: (context, state) => runRedirect(() => traceGuard(state, 'g",
            "redirect: (context, state) => runRedirect(() => traceGuard(state, 'r",
        ],
    );
    assert_eq!(
        count(&c, "redirect: (context, state) => traceGuard("),
        0,
        "{c}"
    );
    assert_eq!(
        count(&c, "redirect: (context, state) => firstRedirect("),
        0,
        "{c}"
    );
}

#[test]
fn an_app_with_no_guard_keeps_the_plain_error_route() {
    let c = code(&[("page.dart", &page("Home"))]);
    has(
        &c,
        &[
            "errorBuilder: (context, state) => routing.errorPage(context, state),",
            "static Widget errorPage(BuildContext context, GoRouterState state) => routerErrorPage(context, state, notFound);",
            "@override Widget errorPage(BuildContext context, GoRouterState state) => AppRoutes.errorPage(context, state);",
        ],
    );
    lacks(&c, &["_guardErrorAt", "guardError"]);
}

#[test]
fn a_guarded_page_gets_its_nearest_error_view_as_its_guard_error() {
    let c = code(&[
        ("page.dart", &page("Home")),
        ("checkout/guard.dart", REF_GUARD),
        ("checkout/page.dart", &page("Checkout")),
        ("error.dart", ROOT_ERROR),
    ]);
    let checkout = matcher(&c, "['checkout']");
    assert!(
        checkout.contains("guardError: (e, st, retry) => _i")
            && checkout.contains(".RootError(error: e, retry: retry)"),
        "{checkout}"
    );
    assert!(!matcher(&c, "[]").contains("guardError"), "{c}");
    has(
        &c,
        &[
            "routerErrorPage(context, state, notFound, guardError: _guardErrorAt)",
            "static Widget? _guardErrorAt(Uri uri, Object error, StackTrace stackTrace, VoidCallback retry) => guardErrorRoutes(uri, base, _matchers, error, stackTrace, retry);",
        ],
    );
}

#[test]
fn an_error_view_that_needs_a_segment_is_not_a_guard_error() {
    let c = code(&[
        ("items/$id/guard.dart", REF_GUARD),
        (
            "items/$id/error.dart",
            "class ItemError extends StatelessWidget { const ItemError({super.key, required int id}); final int id; }",
        ),
        (
            "items/$id/page.dart",
            "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.data}); final int data; }",
        ),
        (
            "items/$id/data.dart",
            "Future<int> data(Ref ref) async => 0;",
        ),
    ]);
    lacks(&c, &["guardError"]);
    // The data's own error view is bound as it was: by its segment.
    has(&c, &["ItemError(id: v.id)"]);
}

#[test]
fn an_error_view_with_a_wrong_type_is_not_a_guard_error() {
    let c = code(&[
        ("guard.dart", REF_GUARD),
        (
            "error.dart",
            "class MyError extends StatelessWidget { const MyError({super.key, required String error}); final String error; }",
        ),
        ("page.dart", &page("Home")),
    ]);
    lacks(&c, &["guardError"]);
}

#[test]
fn positional_and_function_views_take_their_arguments_by_position_and_name() {
    let positional = code(&[
        ("guard.dart", REF_GUARD),
        (
            "error.dart",
            "class ItemError extends StatelessWidget { const ItemError(this.problem, this.again, {super.key}); final Object problem; final VoidCallback again; }",
        ),
        ("page.dart", &page("Home")),
    ]);
    has(&positional, &[".ItemError(e, retry)"]);

    let function = code(&[
        ("guard.dart", REF_GUARD),
        (
            "error.dart",
            "Widget error({required Object error, StackTrace? stackTrace, required VoidCallback retry}) => const SizedBox();",
        ),
        ("page.dart", &page("Home")),
    ]);
    has(
        &function,
        &[".error(error: e, stackTrace: st, retry: retry)"],
    );

    let optional = code(&[
        ("guard.dart", REF_GUARD),
        (
            "error.dart",
            "class QError extends StatelessWidget { const QError({super.key, required Object error, required VoidCallback retry, String? q}); final Object error; final VoidCallback retry; final String? q; }",
        ),
        ("page.dart", &page("Home")),
    ]);
    has(&optional, &[".QError(error: e, retry: retry)"]);
    lacks(&optional, &["final String? q"]);
}

#[test]
fn only_the_routes_of_a_group_get_the_group_error_view() {
    let c = code(&[
        ("(shop)/guard.dart", REF_GUARD),
        ("(shop)/error.dart", ROOT_ERROR),
        ("(shop)/products/page.dart", &page("Products")),
        ("about/page.dart", &page("About")),
    ]);
    assert!(matcher(&c, "['products']").contains("guardError"), "{c}");
    assert!(!matcher(&c, "['about']").contains("guardError"), "{c}");
}

#[test]
fn a_redirect_route_under_an_error_view_gets_one() {
    let c = code(&[
        ("error.dart", ROOT_ERROR),
        ("old/redirect.dart", "String redirect() => '/new';"),
        ("new/page.dart", &page("New")),
    ]);
    assert!(matcher(&c, "['old']").contains("guardError"), "{c}");
}

#[test]
fn a_sibling_that_does_not_nest_gets_one_too() {
    let c = code(&[
        ("guard.dart", REF_GUARD),
        ("error.dart", ROOT_ERROR),
        ("page.dart", &page("Home")),
        ("side/route.dart", "const nest = false;"),
        ("side/page.dart", &page("Side")),
    ]);
    assert!(matcher(&c, "['side']").contains("guardError"), "{c}");
}

#[test]
fn a_case_insensitive_app_says_so_to_the_guard_error_routes() {
    let insensitive = Config {
        case_sensitive: false,
        ..Config::default()
    };
    let c = code_with(
        &insensitive,
        &[
            ("guard.dart", REF_GUARD),
            ("error.dart", ROOT_ERROR),
            ("page.dart", &page("Home")),
        ],
    );
    has(&c, &["retry, caseSensitive: false);"]);
}

#[test]
fn the_routes_json_is_unchanged_by_a_guard_error() {
    let dir = project(&[
        ("guard.dart", REF_GUARD),
        ("error.dart", ROOT_ERROR),
        ("checkout/page.dart", &page("Checkout")),
    ]);
    let cfg = Config::load(dir.path()).unwrap();
    let (_, diags, app) = analyze(&dir.path().join("lib/app"), &cfg).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    let lines = routes::json_lines(&app, "lib/app");
    assert!(!lines.is_empty());
    for line in &lines {
        assert!(
            !line.contains("guardError") && !line.contains("guard_error"),
            "{line}"
        );
    }
}

#[test]
fn adding_an_error_view_above_a_guarded_page_still_swaps() {
    let before = code(&[
        ("page.dart", &page("Home")),
        ("checkout/guard.dart", REF_GUARD),
        ("checkout/page.dart", &page("Checkout")),
    ]);
    let after = code(&[
        ("page.dart", &page("Home")),
        ("checkout/guard.dart", REF_GUARD),
        ("checkout/page.dart", &page("Checkout")),
        ("error.dart", ROOT_ERROR),
    ]);
    let before = read_stamp(&before).expect("a stamp");
    let after = read_stamp(&after).expect("a stamp");
    assert!(before.swaps_to(&after), "a new error view must swap");
}
