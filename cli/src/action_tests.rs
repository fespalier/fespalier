//! `action.dart`: typed writes beside a page (or a section's layout), their generated members and
//! every diagnostic. (The rest of the generator's tests are in `tests.rs`.)

use std::fs;

use crate::build;
use crate::config::Config;

pub(crate) fn project(files: &[(&str, &str)]) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("pubspec.yaml"), "name: demo\n").unwrap();
    for (rel, body) in files {
        let p = dir.path().join("lib/app").join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, body).unwrap();
    }
    dir
}

pub(crate) fn diags(files: &[(&str, &str)]) -> Vec<String> {
    let dir = project(files);
    let (_, diags, _) = build(&dir.path().join("lib/app"), &Config::default()).unwrap();
    diags
        .0
        .iter()
        .map(std::string::ToString::to_string)
        .collect()
}

/// Just the errors: a warning isn't one.
pub(crate) fn errors(files: &[(&str, &str)]) -> String {
    diags(files)
        .into_iter()
        .filter(|d| d.starts_with('✗'))
        .collect::<Vec<_>>()
        .join("\n")
}

pub(crate) fn code(files: &[(&str, &str)]) -> String {
    let dir = project(files);
    let (code, diags, _) = build(&dir.path().join("lib/app"), &Config::default()).unwrap();
    // A page that doesn't take its data is a warning the examples here don't care about.
    let errors: Vec<_> = diags
        .0
        .iter()
        .map(ToString::to_string)
        .filter(|d| d.starts_with('✗'))
        .collect();
    assert!(errors.is_empty(), "{errors:?}");
    code
}

pub(crate) fn has(code: &str, needles: &[&str]) {
    for n in needles {
        assert!(code.contains(n), "missing `{n}` in:\n{code}");
    }
}

pub(crate) fn lacks(code: &str, needles: &[&str]) {
    for n in needles {
        assert!(!code.contains(n), "unexpected `{n}` in:\n{code}");
    }
}

pub(crate) fn widget(class: &str, fields: &str, params: &str) -> String {
    format!(
        "class {class} extends StatelessWidget {{ const {class}({{super.key{params}}}); {fields} }}"
    )
}

pub(crate) const HOME: &str =
    "class HomePage extends StatelessWidget { const HomePage({super.key}); }";

/// `orders/$id/` with a page, and the files given beside it.
fn order(files: &[(&'static str, &'static str)]) -> Vec<(&'static str, &'static str)> {
    // A page that has data.dart beside it takes what it yields.
    let page = if files.iter().any(|(p, _)| *p == "orders/$id/data.dart") {
        "class OrderPage extends StatelessWidget { const OrderPage({super.key, required this.id, required this.order}); final int id; final Order order; }"
    } else {
        "class OrderPage extends StatelessWidget { const OrderPage({super.key, required this.id}); final int id; }"
    };
    let mut all = vec![("page.dart", HOME), ("orders/$id/page.dart", page)];
    all.extend_from_slice(files);
    all
}

const REFUND: &str =
    "Future<Refund> action(Ref ref, {required int id, required RefundInput input}) async => x;";

// --- what is generated ---------------------------------------------------------------------

#[test]
fn an_action_gets_a_provider_a_helper_and_a_hook_on_the_typed_route() {
    let c = code(&order(&[("orders/$id/action.dart", REFUND)]));
    has(
        &c,
        &[
            // The route's members: the provider, `submit` and the hook, keyed by the segment.
            "static final action = _action2_0;",
            "static final submit = (WidgetRef ref, {required int id, required RefundInput input}) => ref.runAction(action(id), input);",
            "static final useAction = (WidgetRef ref, {required int id}) => ref.watchAction(action(id));",
            // The provider runs the function, with the key and the input.
            "final _action2_0 = actionFamily(",
            "(Ref ref, int id, RefundInput input) => _i1.action(ref, id: id, input: input),",
            // Nothing to invalidate: the route has no data.dart and there is no section.
            "invalidates: (int id) => const <ProviderListenable<AsyncValue<Object?>>>[],",
        ],
    );
}

#[test]
fn the_input_type_is_named_through_the_imports_of_the_file() {
    let c = code(&order(&[(
        "orders/$id/action.dart",
        "import '../../models.dart';\nFuture<void> action(Ref ref, {required int id, required RefundInput input}) async {}",
    )]));
    // As a typed `extra` is: from each import of action.dart, shown by name.
    has(&c, &["import 'app/models.dart' show RefundInput;"]);
    let c = code(&order(&[(
        "orders/$id/action.dart",
        "class RefundInput {}\nFuture<void> action(Ref ref, {required int id, required RefundInput input}) async {}",
    )]));
    // A type the file declares is reached through the file's own import.
    has(
        &c,
        &[
            "required _i1.RefundInput input",
            "_i1.RefundInput input) => _i1.action(",
        ],
    );
    let c = code(&order(&[(
        "orders/$id/action.dart",
        "import 'package:m/m.dart' as m;\nFuture<void> action(Ref ref, {required int id, required List<m.Item> input}) async {}",
    )]));
    has(
        &c,
        &[
            "import 'package:m/m.dart' as _ea2_action_m;",
            "List<_ea2_action_m.Item> input",
        ],
    );
}

#[test]
fn the_input_may_be_of_any_type_even_nullable() {
    let c = code(&order(&[(
        "orders/$id/action.dart",
        "Future<void> action(Ref ref, {required int id, required String? input}) async {}",
    )]));
    has(
        &c,
        &["required String? input}) => ref.runAction(action(id), input);"],
    );
}

#[test]
fn a_function_called_action_has_the_plain_names_any_other_its_own() {
    let c = code(&order(&[(
        "orders/$id/action.dart",
        "Future<void> action(Ref ref, {required int id, required Object input}) async {}\n\
         Future<void> approve(Ref ref, {required int id, required Object input}) async {}\n\
         Future<void> reject(Ref ref, {required int id, required Object input}) async {}",
    )]));
    has(
        &c,
        &[
            "static final action = _action2_0;",
            "static final submit = ",
            "static final useAction = ",
            "static final approveAction = _action2_1;",
            "static final approve = ",
            "static final useApprove = ",
            "static final rejectAction = _action2_2;",
            "static final reject = ",
            "static final useReject = ",
        ],
    );
}

#[test]
fn private_functions_and_helpers_that_take_no_ref_are_not_actions() {
    let c = code(&order(&[(
        "orders/$id/action.dart",
        "Future<void> _log(Ref ref, {required int id}) async {}\n\
         int twice(int n) => n * 2;\n\
         Future<void> action(Ref ref, {required int id, required Object input}) async {}",
    )]));
    assert_eq!(c.matches("final _action2_").count(), 1, "{c}");
    lacks(&c, &["twice", "_log"]);
}

#[test]
fn what_an_action_returns_decides_how_its_helpers_run_it() {
    let c = code(&order(&[(
        "orders/$id/action.dart",
        "Future<int> later(Ref ref, {required int id, required int input}) async => input;\n\
         int now(Ref ref, {required int id, required int input}) => input;\n\
         FutureOr<int> either(Ref ref, {required int id, required int input}) => input;\n\
         void nothing(Ref ref, {required int id, required int input}) {}",
    )]));
    has(
        &c,
        &[
            // A Future stays one, a value stays a value (no async gap), a FutureOr stays one.
            "static final later = (WidgetRef ref, {required int id, required int input}) => ref.runAction(laterAction(id), input);",
            "static final useLater = (WidgetRef ref, {required int id}) => ref.watchAction(laterAction(id));",
            "static final now = (WidgetRef ref, {required int id, required int input}) => ref.runActionSync(nowAction(id), input);",
            "static final useNow = (WidgetRef ref, {required int id}) => ref.watchActionSync(nowAction(id));",
            "static final either = (WidgetRef ref, {required int id, required int input}) => ref.runActionOr(eitherAction(id), input);",
            "static final useEither = (WidgetRef ref, {required int id}) => ref.watchActionOr(eitherAction(id));",
            "static final nothing = (WidgetRef ref, {required int id, required int input}) => ref.runActionSync(nothingAction(id), input);",
        ],
    );
}

#[test]
fn a_route_without_keys_gets_a_plain_provider() {
    let c = code(&[
        ("page.dart", HOME),
        (
            "action.dart",
            "Future<void> action(Ref ref, {required String input}) async {}",
        ),
    ]);
    has(
        &c,
        &[
            "static final action = _action0_0;",
            "static final submit = (WidgetRef ref, {required String input}) => ref.runAction(action, input);",
            "static final useAction = (WidgetRef ref) => ref.watchAction(action);",
            "final _action0_0 = actionProvider(",
            "(Ref ref, String input) => _i0.action(ref, input: input),",
            "invalidates: () => const <ProviderListenable<AsyncValue<Object?>>>[],",
        ],
    );
}

#[test]
fn segments_and_query_parameters_key_the_provider_like_a_data_dart() {
    let c = code(&[
        ("page.dart", HOME),
        (
            "shops/$shop/items/$id/page.dart",
            "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.shop, required this.id}); final String shop; final int id; }",
        ),
        (
            "shops/$shop/items/$id/action.dart",
            "Future<void> action(Ref ref, {required String shop, required int id, int? page, List<String> tags = const [], required Object input}) async {}",
        ),
    ]);
    has(
        &c,
        &[
            // Segments in path order, then the query; a list key is a `QueryList`.
            "static final submit = (WidgetRef ref, {required String shop, required int id, int? page, List<String> tags = const [], required Object input}) => ref.runAction(action((shop: shop, id: id, page: page, tags: QueryList(tags))), input);",
            "(Ref ref, ({String shop, int id, int? page, QueryList<String> tags}) k, Object input) => _i1.action(ref, shop: k.shop, id: k.id, page: k.page, tags: k.tags, input: input),",
        ],
    );
    // The query parameters are the route's, so its typed route can write them.
    has(&c, &["final int? page;"]);
}

#[test]
fn a_success_invalidates_the_routes_data_and_the_sections_above_it() {
    let c = code(&[
        ("page.dart", HOME),
        (
            "(shop)/data.dart",
            "Future<Shop> data(Ref ref) async => Shop();",
        ),
        (
            "(shop)/layout.dart",
            &widget(
                "ShopLayout",
                "final Widget child; final Shop shop;",
                ", required this.child, required this.shop",
            ),
        ),
        (
            "(shop)/orders/$id/page.dart",
            "class OrderPage extends StatelessWidget { const OrderPage({super.key, required this.id, required this.order}); final int id; final Order order; }",
        ),
        (
            "(shop)/orders/$id/data.dart",
            "Future<Order> data(Ref ref, {required int id}) async => x;",
        ),
        (
            "(shop)/orders/$id/action.dart",
            "Future<void> action(Ref ref, {required int id, required Object input}) async {}",
        ),
    ]);
    // The set `AppRoutes.dataAt` lists: the section's, outermost first, then the route's own.
    has(
        &c,
        &[
            "invalidates: (int id) => <ProviderListenable<AsyncValue<Object?>>>[_data1, _data3(id)],",
        ],
    );
}

#[test]
fn a_sections_data_keyed_by_a_segment_is_invalidated_for_the_actions_key() {
    let c = code(&[
        ("page.dart", HOME),
        (
            "teams/$teamId/data.dart",
            "Future<Team> data(Ref ref, {required String teamId}) async => x;",
        ),
        (
            "teams/$teamId/layout.dart",
            &widget(
                "TeamLayout",
                "final Widget child; final Team team;",
                ", required this.child, required this.team",
            ),
        ),
        (
            "teams/$teamId/members/page.dart",
            &widget(
                "MembersPage",
                "final String teamId;",
                ", required this.teamId",
            ),
        ),
        (
            "teams/$teamId/members/action.dart",
            "Future<void> add(Ref ref, {required String teamId, required String input}) async {}",
        ),
    ]);
    has(
        &c,
        &[
            "invalidates: (String teamId) => <ProviderListenable<AsyncValue<Object?>>>[_data2(teamId)],",
        ],
    );
    // A record key is spelled out field by field.
    let c = code(&[
        ("page.dart", HOME),
        (
            "shops/$shop/data.dart",
            "Future<Shop> data(Ref ref, {required String shop}) async => x;",
        ),
        (
            "shops/$shop/layout.dart",
            &widget(
                "ShopLayout",
                "final Widget child; final Shop thing;",
                ", required this.child, required this.thing",
            ),
        ),
        (
            "shops/$shop/items/$id/page.dart",
            "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.shop, required this.id}); final String shop; final int id; }",
        ),
        (
            "shops/$shop/items/$id/data.dart",
            "Future<Item> data(Ref ref, {required String shop, required int id}) async => x;",
        ),
        (
            "shops/$shop/items/$id/action.dart",
            "Future<void> action(Ref ref, {required String shop, required int id, required Object input}) async {}",
        ),
    ]);
    has(
        &c,
        &[
            "invalidates: (({String shop, int id}) k) => <ProviderListenable<AsyncValue<Object?>>>[_data2(k.shop), _data4((shop: k.shop, id: k.id))],",
        ],
    );
}

#[test]
fn a_provider_written_by_hand_and_a_selected_one_are_invalidated_too() {
    let c = code(&order(&[
        (
            "orders/$id/data.dart",
            "final data = FutureProvider.family<Order, int>((ref, id) async => x);",
        ),
        (
            "orders/$id/action.dart",
            "Future<void> action(Ref ref, {required int id, required Object input}) async {}",
        ),
    ]));
    has(&c, &["[_i1.data(id)],"]);
    let c = code(&order(&[
        (
            "orders/$id/data.dart",
            "ProviderListenable<AsyncValue<Order>> data({required int id}) => orderProvider(id);",
        ),
        (
            "orders/$id/action.dart",
            "Future<void> action(Ref ref, {required int id, required Object input}) async {}",
        ),
    ]));
    has(&c, &["[_data2(id)],"]);
}

#[test]
fn invalidates_replaces_the_default_set() {
    let files = |list: &'static str| {
        order(&[
            (
                "orders/$id/data.dart",
                "Future<Order> data(Ref ref, {required int id}) async => x;",
            ),
            (
                "orders/$id/refund/page.dart",
                "class RefundPage extends StatelessWidget { const RefundPage({super.key, required this.id}); final int id; }",
            ),
            (
                "orders/$id/refund/data.dart",
                "Future<String> data(Ref ref, {required int id}) async => '';",
            ),
            ("orders/$id/refund/action.dart", list),
        ])
    };
    // Another route's data, instead of the route's own.
    let c = code(&files(
        "const invalidates = [OrderRoute];\nFuture<void> action(Ref ref, {required int id, required Object input}) async {}",
    ));
    has(
        &c,
        &["invalidates: (int id) => <ProviderListenable<AsyncValue<Object?>>>[_data2(id)],"],
    );
    lacks(&c, &["_data4(id)"]);
    // Both, in the order written; a name listed twice counts once.
    let c = code(&files(
        "const invalidates = [RefundRoute, OrderRoute, RefundRoute,];\nFuture<void> action(Ref ref, {required int id, required Object input}) async {}",
    ));
    has(&c, &["[_data3(id), _data2(id)],"]);
    // An empty list leaves everything alone.
    let c = code(&files(
        "const invalidates = <Object>[];\nFuture<void> action(Ref ref, {required int id, required Object input}) async {}",
    ));
    has(
        &c,
        &["invalidates: (int id) => const <ProviderListenable<AsyncValue<Object?>>>[],"],
    );
}

#[test]
fn invalidates_can_name_a_section_and_a_route_elsewhere() {
    let c = code(&[
        ("page.dart", HOME),
        (
            "teams/$teamId/data.dart",
            "Future<Team> data(Ref ref, {required String teamId}) async => x;",
        ),
        (
            "teams/$teamId/layout.dart",
            &widget(
                "TeamLayout",
                "final Widget child; final Team team;",
                ", required this.child, required this.team",
            ),
        ),
        (
            "teams/$teamId/members/page.dart",
            &widget("MembersPage", "", ""),
        ),
        (
            "stats/page.dart",
            &widget("StatsPage", "final Stats stats;", ", required this.stats"),
        ),
        ("stats/data.dart", "Future<Stats> data(Ref ref) async => x;"),
        (
            "teams/$teamId/members/action.dart",
            "const invalidates = [TeamsTeamIdSection, StatsRoute];\nFuture<void> action(Ref ref, {required String teamId, required Object input}) async {}",
        ),
    ]);
    has(&c, &["[_data3(teamId), _data1],"]);
}

#[test]
fn a_section_with_data_gets_typed_action_members_on_its_handle() {
    let c = code(&[
        ("page.dart", HOME),
        (
            "teams/$teamId/data.dart",
            "Future<Team> data(Ref ref, {required String teamId}) async => x;",
        ),
        (
            "teams/$teamId/layout.dart",
            &widget(
                "TeamLayout",
                "final Widget child; final Team team;",
                ", required this.child, required this.team",
            ),
        ),
        (
            "teams/$teamId/members/page.dart",
            &widget("MembersPage", "", ""),
        ),
        (
            "teams/$teamId/action.dart",
            "Future<void> rename(Ref ref, {required String teamId, required String input}) async {}",
        ),
    ]);
    has(
        &c,
        &[
            "abstract final class TeamsTeamIdSection {",
            "static final data = _data2;",
            "static final renameAction = _action2_0;",
            "static final rename = (WidgetRef ref, {required String teamId, required String input}) => ref.runAction(renameAction(teamId), input);",
            "static final useRename = (WidgetRef ref, {required String teamId}) => ref.watchAction(renameAction(teamId));",
            "invalidates: (String teamId) => <ProviderListenable<AsyncValue<Object?>>>[_data2(teamId)],",
        ],
    );
}

#[test]
fn a_section_without_data_still_gets_a_handle_for_its_actions() {
    let c = code(&[
        ("page.dart", HOME),
        (
            "(shop)/layout.dart",
            &widget("ShopLayout", "final Widget child;", ", required this.child"),
        ),
        ("(shop)/cart/page.dart", &widget("CartPage", "", "")),
        (
            "(shop)/action.dart",
            "Future<void> clear(Ref ref, {required Object input}) async {}",
        ),
    ]);
    has(
        &c,
        &[
            "abstract final class ShopSection {",
            "Typed access to the action.dart of the section `(shop)/` wraps",
            "static final clearAction = _action1_0;",
        ],
    );
    // No data: none of the data members, and nothing to invalidate.
    lacks(
        &c,
        &[
            "static final data = _data",
            "ref.watch(data",
            "ref.prefetchData",
        ],
    );
    has(
        &c,
        &["invalidates: () => const <ProviderListenable<AsyncValue<Object?>>>[],"],
    );
}

#[test]
fn a_sections_query_parameters_key_its_actions() {
    let c = code(&[
        ("page.dart", HOME),
        (
            "reports/data.dart",
            "Future<Report> data(Ref ref, {String? period}) async => x;",
        ),
        (
            "reports/layout.dart",
            &widget(
                "ReportsLayout",
                "final Widget child; final Report report;",
                ", required this.child, required this.report",
            ),
        ),
        ("reports/monthly/page.dart", &widget("MonthlyPage", "", "")),
        (
            "reports/action.dart",
            "Future<void> publish(Ref ref, {String? period, required Object input}) async {}",
        ),
    ]);
    has(
        &c,
        &[
            "static final publish = (WidgetRef ref, {String? period, required Object input}) => ref.runAction(publishAction(period), input);",
            "invalidates: (String? period) => <ProviderListenable<AsyncValue<Object?>>>[_data1(period)],",
        ],
    );
}

#[test]
fn the_route_table_tags_a_route_with_an_action() {
    let dir = project(&order(&[
        (
            "orders/$id/data.dart",
            "Future<Order> data(Ref ref, {required int id}) async => x;",
        ),
        ("orders/$id/action.dart", REFUND),
    ]));
    let (code, _, _) = build(&dir.path().join("lib/app"), &Config::default()).unwrap();
    // The header table of app.g.dart, which `fsp routes` prints too.
    assert!(
        code.contains("OrderRoute  orders/$id/page.dart  (data, action)"),
        "{code}"
    );
}

#[test]
fn output_is_deterministic() {
    let files = order(&[(
        "orders/$id/action.dart",
        "Future<void> b(Ref ref, {required int id, required Object input}) async {}\n\
         Future<void> a(Ref ref, {required int id, required Object input}) async {}\n\
         Future<void> action(Ref ref, {required int id, required Object input}) async {}",
    )]);
    assert_eq!(code(&files), code(&files));
    // In the order the file declares them.
    let c = code(&files);
    let at = |n: &str| c.find(n).unwrap();
    assert!(
        at("static final bAction") < at("static final aAction"),
        "{c}"
    );
    assert!(
        at("static final aAction") < at("static final action"),
        "{c}"
    );
}

// --- diagnostics -------------------------------------------------------------------------------

#[test]
fn an_action_dart_with_nothing_beside_it_is_an_error() {
    let e = errors(&[("page.dart", HOME), ("lonely/action.dart", REFUND)]);
    assert!(
        e.contains("lonely/action.dart  action.dart has nothing to write to: put it beside a page.dart (the route it belongs to) or, in a folder without a page, beside the layout.dart of a section"),
        "{e}"
    );
    // A redirect.dart is not a page.
    let e = errors(&[
        ("page.dart", HOME),
        ("old/redirect.dart", "String redirect() => '/';"),
        (
            "old/action.dart",
            "Future<void> action(Ref ref, {required Object input}) async {}",
        ),
    ]);
    assert!(
        e.contains("old/action.dart  action.dart has nothing to write to"),
        "{e}"
    );
}

#[test]
fn an_action_dart_without_an_action_is_an_error() {
    let e = errors(&[("page.dart", HOME), ("action.dart", "int one() => 1;")]);
    assert!(
        e.contains("action.dart  expected `Future<T> action(Ref ref, {...segments, required Input input})`; any public function that takes a `Ref` first is an action"),
        "{e}"
    );
}

#[test]
fn input_is_required_named_and_typed() {
    let e = errors(&order(&[(
        "orders/$id/action.dart",
        "Future<void> action(Ref ref, {required int id}) async {}",
    )]));
    assert!(
        e.contains("orders/$id/action.dart:1  action() needs an `input` parameter, the value it writes: `{required Input input}`; segments and query parameters are its other named parameters"),
        "{e}"
    );
    let e = errors(&order(&[(
        "orders/$id/action.dart",
        "Future<void> action(Ref ref, Object input, {required int id}) async {}",
    )]));
    assert!(
        e.contains("action() takes `input` as a named parameter, e.g. `{required Input input}`"),
        "{e}"
    );
    let e = errors(&order(&[(
        "orders/$id/action.dart",
        "Future<void> action(Ref ref, {required int id, Object? input}) async {}",
    )]));
    assert!(
        e.contains("`input` of action() must be `required`: there is nothing to run without it"),
        "{e}"
    );
    let e = errors(&order(&[(
        "orders/$id/action.dart",
        "Future<void> action(Ref ref, {required int id, required input}) async {}",
    )]));
    assert!(
        e.contains("give `input` a type: it is what the action is called with"),
        "{e}"
    );
}

#[test]
fn a_parameter_that_is_neither_a_segment_a_query_parameter_nor_input_is_an_error() {
    let e = errors(&order(&[(
        "orders/$id/action.dart",
        "Future<void> action(Ref ref, {required int id, required int amount, required Object input}) async {}",
    )]));
    assert!(
        e.contains("orders/$id/action.dart:1  `amount` isn't a segment of this path ($id); for a query parameter make it optional and nullable, e.g. `String? amount`"),
        "{e}"
    );
    // A query type that is not one says so.
    let e = errors(&order(&[(
        "orders/$id/action.dart",
        "Future<void> action(Ref ref, {required int id, Object? note, required Object input}) async {}",
    )]));
    assert!(
        e.contains("`note` isn't a segment of this path ($id)"),
        "{e}"
    );
    // A positional parameter after the Ref.
    let e = errors(&order(&[(
        "orders/$id/action.dart",
        "Future<void> action(Ref ref, int id, {required Object input}) async {}",
    )]));
    assert!(
        e.contains("action() takes segments as named parameters, e.g. `{required int id}`"),
        "{e}"
    );
}

#[test]
fn a_segment_type_that_disagrees_is_the_usual_error() {
    let e = errors(&order(&[(
        "orders/$id/action.dart",
        "Future<void> action(Ref ref, {required String id, required Object input}) async {}",
    )]));
    assert!(e.contains("`$id`"), "{e}");
}

#[test]
fn the_function_must_take_a_ref_and_say_what_it_returns() {
    let e = errors(&order(&[(
        "orders/$id/action.dart",
        "Future<void> action({required int id, required Object input}) async {}",
    )]));
    assert!(e.contains("action() must take `Ref ref` first"), "{e}");
    let e = errors(&order(&[(
        "orders/$id/action.dart",
        "action(Ref ref, {required int id, required Object input}) async {}",
    )]));
    assert!(
        e.contains("action() needs an explicit return type (Future<T>, FutureOr<T> or T)"),
        "{e}"
    );
    let e = errors(&order(&[(
        "orders/$id/action.dart",
        "Stream<int> action(Ref ref, {required int id, required Object input}) => x;",
    )]));
    assert!(
        e.contains("action() returns a Stream, but an action is one write with one result: return a Future<T>, FutureOr<T> or T"),
        "{e}"
    );
    let e = errors(&order(&[(
        "orders/$id/action.dart",
        "Future action(Ref ref, {required int id, required Object input}) async {}",
    )]));
    assert!(
        e.contains("give the Future of action() its type argument, e.g. `Future<Refund>`"),
        "{e}"
    );
}

#[test]
fn invalidates_must_be_a_const_list_of_known_names() {
    let with = |list: &'static str| {
        errors(&order(&[
            (
                "orders/$id/data.dart",
                "Future<Order> data(Ref ref, {required int id}) async => x;",
            ),
            ("orders/$id/action.dart", list),
        ]))
    };
    let tail = "\nFuture<void> action(Ref ref, {required int id, required Object input}) async {}";
    let shape = "`invalidates` must be a const list literal of typed routes and sections: `const invalidates = [OrderRoute, TeamsTeamIdSection];`, or `const invalidates = <Object>[];` for none";
    for list in [
        "final invalidates = [OrderRoute];",
        "const invalidates = OrderRoute;",
        "const invalidates = [OrderRoute.data];",
        "const invalidates = ['a'];",
        "const invalidates = [OrderRoute, ...more];",
    ] {
        let e = with(Box::leak(format!("{list}{tail}").into_boxed_str()));
        assert!(e.contains(shape), "{list}: {e}");
        assert!(e.contains("orders/$id/action.dart:1"), "{list}: {e}");
    }
    let e = with(Box::leak(
        format!("const invalidates = [NopeRoute];{tail}").into_boxed_str(),
    ));
    assert!(
        e.contains("`invalidates` names `NopeRoute`, which is neither a typed route nor a section handle; list classes like `OrderRoute` or `TeamsTeamIdSection`"),
        "{e}"
    );
    // A route with no data.dart has nothing to invalidate.
    let e = errors(&[
        ("page.dart", HOME),
        ("plain/page.dart", &widget("PlainPage", "", "")),
        (
            "plain/action.dart",
            "const invalidates = [PlainRoute];\nFuture<void> action(Ref ref, {required Object input}) async {}",
        ),
    ]);
    assert!(
        e.contains("`invalidates` names `PlainRoute`, which has no data.dart: there is nothing to invalidate"),
        "{e}"
    );
}

#[test]
fn an_action_must_take_the_keys_of_the_data_it_invalidates() {
    // The default set: the route's own data, keyed by a query parameter the action doesn't take.
    let e = errors(&[
        ("page.dart", HOME),
        (
            "search/page.dart",
            &widget("SearchPage", "final String r;", ", required this.r"),
        ),
        (
            "search/data.dart",
            "Future<String> data(Ref ref, {String? q}) async => '';",
        ),
        (
            "search/action.dart",
            "Future<void> save(Ref ref, {required Object input}) async {}",
        ),
    ]);
    assert!(
        e.contains("search/data.dart is keyed by `q`, which save() doesn't take, so it can't tell which one to invalidate after a success: take it (`String? q`), or list what to invalidate with `const invalidates = [...]`"),
        "{e}"
    );
    // A listed route: the same, with the other way out.
    let e = errors(&[
        ("page.dart", HOME),
        (
            "shops/$shop/page.dart",
            &widget("ShopPage", "final Shop s;", ", required this.s"),
        ),
        (
            "shops/$shop/data.dart",
            "Future<Shop> data(Ref ref, {required String shop}) async => x;",
        ),
        ("other/page.dart", &widget("OtherPage", "", "")),
        (
            "other/action.dart",
            "const invalidates = [ShopRoute];\nFuture<void> save(Ref ref, {required Object input}) async {}",
        ),
    ]);
    assert!(
        e.contains("shops/$shop/data.dart is keyed by `shop`, which save() doesn't take, so it can't tell which one to invalidate after a success: take it (`String shop`), or leave that route out of `invalidates`"),
        "{e}"
    );
    // With `<Object>[]` there is nothing to key.
    let e = errors(&[
        ("page.dart", HOME),
        (
            "search/page.dart",
            &widget("SearchPage", "final String r;", ", required this.r"),
        ),
        (
            "search/data.dart",
            "Future<String> data(Ref ref, {String? q}) async => '';",
        ),
        (
            "search/action.dart",
            "const invalidates = <Object>[];\nFuture<void> save(Ref ref, {required Object input}) async {}",
        ),
    ]);
    assert!(e.is_empty(), "{e}");
}

#[test]
fn helper_names_may_not_collide_with_the_route_or_with_each_other() {
    // A function called like a member of the route class.
    let e = errors(&order(&[(
        "orders/$id/action.dart",
        "Future<void> refresh(Ref ref, {required int id, required Object input}) async {}",
    )]));
    assert!(
        e.contains("the helper of refresh() would be called `refresh`, which is already a member of the typed route; rename the function"),
        "{e}"
    );
    // The URL-state members the route class has too (since 0.5.0).
    for name in ["of", "maybeOf", "copyWith"] {
        let source: &'static str = Box::leak(
            format!(
            "Future<void> {name}(Ref ref, {{required int id, required Object input}}) async {{}}"
            )
            .into_boxed_str(),
        );
        let e = errors(&order(&[("orders/$id/action.dart", source)]));
        assert!(
            e.contains(&format!(
                "would be called `{name}`, which is already a member of the typed route"
            )),
            "{e}"
        );
    }
    // A segment (a field of the route class).
    let e = errors(&[
        ("page.dart", HOME),
        (
            "$approve/page.dart",
            "class ApprovePage extends StatelessWidget { const ApprovePage({super.key, required this.approve}); final String approve; }",
        ),
        (
            "$approve/action.dart",
            "Future<void> approve(Ref ref, {required String approve, required Object input}) async {}",
        ),
    ]);
    assert!(
        e.contains("which is already `approve`, a segment or query parameter of the route; rename the function"),
        "{e}"
    );
    // `action` and a function called `submit` both have `submit`.
    let e = errors(&order(&[(
        "orders/$id/action.dart",
        "Future<void> action(Ref ref, {required int id, required Object input}) async {}\n\
         Future<void> submit(Ref ref, {required int id, required Object input}) async {}",
    )]));
    assert!(
        e.contains("the helper of submit() would be called `submit`, which is already the helper of action(); rename the function"),
        "{e}"
    );
    // `useAction` is the hook of `action`.
    let e = errors(&order(&[(
        "orders/$id/action.dart",
        "Future<void> action(Ref ref, {required int id, required Object input}) async {}\n\
         Future<void> useAction(Ref ref, {required int id, required Object input}) async {}",
    )]));
    assert!(
        e.contains("the helper of useAction() would be called `useAction`, which is already the hook of action(); rename the function"),
        "{e}"
    );
    // Two actions whose provider and helper names meet: `go` is a route member, `goAction` is not.
    let e = errors(&order(&[(
        "orders/$id/action.dart",
        "Future<void> go(Ref ref, {required int id, required Object input}) async {}",
    )]));
    assert!(
        e.contains("`go`, which is already a member of the typed route"),
        "{e}"
    );
}

#[test]
fn a_sections_action_keys_cannot_take_the_names_of_the_handles_members() {
    let e = errors(&[
        ("page.dart", HOME),
        (
            "(shop)/layout.dart",
            &widget("ShopLayout", "final Widget child;", ", required this.child"),
        ),
        ("(shop)/cart/page.dart", &widget("CartPage", "", "")),
        (
            "(shop)/action.dart",
            "Future<void> clear(Ref ref, {String? watch, required Object input}) async {}",
        ),
    ]);
    assert!(
        e.contains("`watch` can't be a key of a section's action: the section's typed handle has a member called `watch`; rename it"),
        "{e}"
    );
}

#[test]
fn a_section_handle_name_clash_is_reported_with_an_action_only_section_too() {
    let e = errors(&[
        ("page.dart", HOME),
        (
            "(a)/layout.dart",
            &widget("ALayout", "final Widget child;", ", required this.child"),
        ),
        ("(a)/y/page.dart", &widget("YPage", "", "")),
        (
            "(a)/action.dart",
            "Future<void> save(Ref ref, {required Object input}) async {}",
        ),
        (
            "a/layout.dart",
            &widget("BLayout", "final Widget child;", ", required this.child"),
        ),
        ("a/z/page.dart", &widget("ZPage", "", "")),
        (
            "a/action.dart",
            "Future<void> save(Ref ref, {required Object input}) async {}",
        ),
    ]);
    assert!(
        e.contains("the section's typed handle `ASection` is already taken by (a)/action.dart"),
        "{e}"
    );
}

#[test]
fn a_well_formed_project_with_actions_has_no_diagnostics() {
    // The code and the examples are what really check this; this keeps the success paths honest.
    assert!(diags(&order(&[("orders/$id/action.dart", REFUND)])).is_empty());
}

/// A tree with an order route (data, a `refund` action) and a team section (data, an action).
fn zero_seven_tree() -> Vec<(&'static str, &'static str)> {
    vec![
        ("page.dart", HOME),
        (
            "orders/$id/page.dart",
            "class OrderPage extends StatelessWidget { const OrderPage({super.key, required this.id, required this.order}); final int id; final Order order; }",
        ),
        (
            "orders/$id/data.dart",
            "Future<Order> data(Ref ref, {required int id}) async => x;",
        ),
        ("orders/$id/action.dart", REFUND),
        (
            "teams/$teamId/data.dart",
            "Future<Team> data(Ref ref, {required String teamId}) async => x;",
        ),
        (
            "teams/$teamId/layout.dart",
            "class TeamLayout extends StatelessWidget { const TeamLayout({super.key, required this.child, required this.team}); final Widget child; final Team team; }",
        ),
        (
            "teams/$teamId/members/page.dart",
            "class MembersPage extends StatelessWidget { const MembersPage({super.key, required this.team, required this.teamId}); final Team team; final String teamId; }",
        ),
        (
            "teams/$teamId/action.dart",
            "Future<void> addMember(Ref ref, {required String teamId, required String input}) async {}",
        ),
    ]
}

/// What 0.7.0 generated for these files, copied from a run of `fsp gen` at 5f7f39d: an app
/// with no `form()`, `validate()` or `optimistic()` must still get exactly this (since 0.8.1).
#[test]
fn no_companions_generate_what_0_7_0_did() {
    let c = code(&zero_seven_tree());
    has(
        &c,
        &[
            // The three members of an action, on the route and on the section handle.
            "  static final action = _action2_0;\n",
            "  static final submit = (WidgetRef ref, {required int id, required RefundInput input}) => ref.runAction(action(id), input);\n",
            "  static final useAction = (WidgetRef ref, {required int id}) => ref.watchAction(action(id));\n}\n",
            "  static final addMemberAction = _action4_0;\n",
            "  static final addMember = (WidgetRef ref, {required String teamId, required String input}) => ref.runAction(addMemberAction(teamId), input);\n",
            "  static final useAddMember = (WidgetRef ref, {required String teamId}) => ref.watchAction(addMemberAction(teamId));\n}\n",
            // The typed `watch` of the data an action invalidates.
            "  static final watch = (WidgetRef ref, {required int id}) => ref.watch(data(id));\n",
            "  static final watch = (WidgetRef ref, {required String teamId}) => ref.watch(data(teamId));\n",
            // The two provider definitions, whole.
            "/// `action()` of orders/$id/action.dart: its state, and what it invalidates after a success.\n\
             final _action2_0 = actionFamily(\n\
             \x20 (Ref ref, int id, RefundInput input) => _i2.action(ref, id: id, input: input),\n\
             \x20 invalidates: (int id) => <ProviderListenable<AsyncValue<Object?>>>[_data2(id)],\n\
             \x20 site: 'a2_0',\n\
             );\n",
            "/// `addMember()` of teams/$teamId/action.dart: its state, and what it invalidates after a success.\n\
             final _action4_0 = actionFamily(\n\
             \x20 (Ref ref, String teamId, String input) => _i5.addMember(ref, teamId: teamId, input: input),\n\
             \x20 invalidates: (String teamId) => <ProviderListenable<AsyncValue<Object?>>>[_data4(teamId)],\n\
             \x20 site: 'a4_0',\n\
             );\n",
            // The read sites: `DataView` and `SectionView` as they were.
            "(v) => DataView(\n\
             \x20               watch: (ref) => watchData(ref, 'd2', _data2(v.id)),\n\
             \x20               refresh: (ref) => ref.invalidate(_data2(v.id)),\n\
             \x20               data: (d) => _i3.OrderPage(id: v.id, order: d),\n\
             \x20               loading: () => const DefaultLoading(),\n\
             \x20               error: (e, st, retry) => DefaultError(error: e, retry: retry),\n\
             \x20               keepPrevious: true,\n\
             \x20             ),\n",
            "(v) => SectionView(\n\
             \x20                   watch: (ref) => watchData(ref, 'd4', _data4(v.teamId)),\n\
             \x20                   data: (s4) => _i7.MembersPage(team: s4, teamId: v.teamId),\n\
             \x20                 ),\n",
        ],
    );
    lacks(
        &c,
        &[
            "optimistic",
            "Optimistic",
            "useActionForm",
            "validate:",
            "useForm",
            // Nor telemetry or observe.dart hooks (since 0.8.1): neither is opted into.
            "TelemetrySite",
            "AppRoutes.attach",
            "_observeAt",
            // The data provider is `traceData(..., data(...))` as it always was, not the
            // `traceDataCall(..., () => data(...))` that only `telemetry: true` writes (0.9.0).
            "traceDataCall",
        ],
    );
    has(
        &c,
        &[
            "(Ref ref, int id) => traceData(ref, 'd2', id, _i1.data(ref, id: id)),",
            "(Ref ref, String teamId) => traceData(ref, 'd4', teamId, _i4.data(ref, teamId: teamId)),",
        ],
    );
}
