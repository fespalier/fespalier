//! `form()`, `validate()` and `optimistic()` beside an action (since 0.8.1): the companions the
//! resolver finds by name, the `useForm` hook and the optimistic layers they generate, and every
//! diagnostic. (The actions themselves are in `action_tests.rs`.)

use crate::action_tests::{HOME, code, diags, errors, has, lacks, widget};

const PROFILE_PAGE: &str = "class NicknamePage extends StatelessWidget { const NicknamePage({super.key, required this.profile}); final Profile profile; }";
const PROFILE_DATA: &str = "Future<Profile> data(Ref ref) async => x;";

/// `nickname/` with a page and data.dart, and the action.dart given.
fn nickname(action: &str) -> Vec<(&str, &str)> {
    vec![
        ("page.dart", HOME),
        ("nickname/page.dart", PROFILE_PAGE),
        ("nickname/data.dart", PROFILE_DATA),
        ("nickname/action.dart", action),
    ]
}

const FIELDS: &str = "typedef NicknameFields = ({String nickname, int? age, bool newsletter});\n";
const FORM: &str = "NicknameFields form(Profile profile) => (nickname: profile.nickname, age: profile.age, newsletter: profile.newsletter);\n";
const VALIDATE: &str = "FieldErrors? validate(NicknameFields input) => null;\n";
const OPTIMISTIC: &str = "Profile optimistic(Profile current, NicknameFields input) => current;\n";
const ACTION: &str =
    "Future<Profile> action(Ref ref, {required NicknameFields input}) async => x;\n";

fn all() -> String {
    format!("{FIELDS}{FORM}{VALIDATE}{OPTIMISTIC}{ACTION}")
}

/// The single error the files give, whole: `✗ file:line  message`.
fn error(files: &[(&str, &str)]) -> String {
    let e = errors(files);
    assert_eq!(e.lines().count(), 1, "{e}");
    e
}

/// The single error of an action.dart in `nickname/`, which must be on line `line`.
fn action_error(action: &str, line: usize, msg: &str) {
    let e = error(&nickname(action));
    assert_eq!(e, format!("✗ nickname/action.dart:{line}  {msg}"));
}

// --- what is generated ---------------------------------------------------------------------

#[test]
fn companions_are_not_actions() {
    let c = code(&nickname(&all()));
    assert_eq!(c.matches("static final action = _action1_0;").count(), 1);
    lacks(
        &c,
        &[
            "formAction",
            "validateAction",
            "optimisticAction",
            "_action1_1",
        ],
    );
    has(
        &c,
        &[
            "static final useForm = (WidgetRef ref, {required Profile data, ActionFormValidation validation = ActionFormValidation.afterSubmit, bool resetOnSuccess = false, ActionFormMessages messages = const ActionFormMessages()}) => useActionForm(ref, action, data: data, initial: () => _i2.form(data), fields: (ActionFormFields<_i2.NicknameFields> f) => (nickname: f.text('nickname', (v) => v.nickname, FieldCodec.text), age: f.text('age', (v) => v.age, FieldCodec.optionalInteger), newsletter: f.value('newsletter', (v) => v.newsletter)), input: (f) => (nickname: f.nickname.value, age: f.age.value, newsletter: f.newsletter.value), validate: _i2.validate, validation: validation, resetOnSuccess: resetOnSuccess, messages: messages);\n}\n",
            "final _optimistic1 = optimisticLayer(_data1);",
            "/// What reads of nickname/data.dart show while a write that patches it is in flight (`optimistic()` of nickname/action.dart). Since 0.8.1.",
            "final _action1_0 = actionProvider(\n  (Ref ref, _i2.NicknameFields input) => _i2.action(ref, input: input),\n  invalidates: () => <ProviderListenable<AsyncValue<Object?>>>[_data1],\n  validate: _i2.validate,\n  optimistic: () => _optimistic1.patch(_i2.optimistic),\n  site: 'a1_0',\n);",
            // The read sites go through the layer.
            "optimistic: (ref) => ref.watch(_optimistic1),",
            "static final watch = (WidgetRef ref) => ref.watchOptimistic(data, _optimistic1);",
        ],
    );
}

#[test]
fn named_companions_follow_their_action() {
    let c = code(&nickname(&format!(
        "{FIELDS}\
         NicknameFields approveForm(Profile profile) => (nickname: profile.nickname, age: profile.age, newsletter: profile.newsletter);\n\
         FieldErrors? approveValidate(NicknameFields input) => null;\n\
         Profile approveOptimistic(Profile current, NicknameFields input) => current;\n\
         Future<Profile> approve(Ref ref, {{required NicknameFields input}}) async => x;\n"
    )));
    has(
        &c,
        &[
            "static final approveAction = _action1_0;",
            "static final useApproveForm = (WidgetRef ref, {required Profile data,",
            "useActionForm(ref, approveAction, data: data, initial: () => _i2.approveForm(data),",
            "validate: _i2.approveValidate,",
            "optimistic: () => _optimistic1.patch(_i2.approveOptimistic),",
            "(`approveOptimistic()` of nickname/action.dart)",
        ],
    );
    lacks(&c, &["approveFormAction", "useForm "]);
}

#[test]
fn a_form_alone_changes_the_provider_not_at_all() {
    let c = code(&nickname(&format!("{FIELDS}{FORM}{ACTION}")));
    has(
        &c,
        &["static final useForm = ", "initial: () => _i2.form(data),"],
    );
    lacks(
        &c,
        &[
            "validate:",
            "optimistic",
            "Optimistic",
            "ref.watchOptimistic",
        ],
    );
    // And validate or optimistic alone give no form.
    let c = code(&nickname(&format!("{FIELDS}{VALIDATE}{ACTION}")));
    has(&c, &["  validate: _i2.validate,\n"]);
    lacks(&c, &["useForm", "useActionForm", "optimistic"]);
}

#[test]
fn form_reads_inline_record_and_typedef() {
    let input = "({String a, String? b, int c, int? d, double e, num? f, bool g, Color h})";
    let body = "(a: '', b: null, c: 1, d: null, e: 1.0, f: null, g: true, h: x)";
    let fields = "(a: f.text('a', (v) => v.a, FieldCodec.text), b: f.text('b', (v) => v.b, FieldCodec.optionalText), c: f.text('c', (v) => v.c, FieldCodec.integer), d: f.text('d', (v) => v.d, FieldCodec.optionalInteger), e: f.text('e', (v) => v.e, FieldCodec.decimal), f: f.text('f', (v) => v.f, FieldCodec.optionalNumber), g: f.value('g', (v) => v.g), h: f.value('h', (v) => v.h))";
    let inline = format!(
        "{input} form() => {body};\nFuture<void> action(Ref ref, {{required {input} input}}) async {{}}\n"
    );
    let c = code(&[
        ("page.dart", HOME),
        ("nickname/page.dart", &widget("NicknamePage", "", "")),
        ("nickname/action.dart", &inline),
    ]);
    has(
        &c,
        &[
            &format!("fields: (ActionFormFields<{input}> f) => {fields}"),
            "initial: () => _i1.form(), ",
        ],
    );
    let via_typedef = format!(
        "typedef Fields = {input};\nFields form() => {body};\nFuture<void> action(Ref ref, {{required Fields input}}) async {{}}\n"
    );
    let c = code(&[
        ("page.dart", HOME),
        ("nickname/page.dart", &widget("NicknamePage", "", "")),
        ("nickname/action.dart", &via_typedef),
    ]);
    has(
        &c,
        &[&format!(
            "fields: (ActionFormFields<_i1.Fields> f) => {fields}"
        )],
    );
}

#[test]
fn form_hook_takes_data_when_form_does() {
    let c = code(&nickname(&all()));
    has(
        &c,
        &[
            "{required Profile data, ActionFormValidation",
            "data: data, initial: () => _i2.form(data),",
        ],
    );
    let c = code(&[
        ("page.dart", HOME),
        ("nickname/page.dart", &widget("NicknamePage", "", "")),
        (
            "nickname/action.dart",
            "typedef F = ({String name});\nF form() => (name: '');\nFuture<void> action(Ref ref, {required F input}) async {}\n",
        ),
    ]);
    has(
        &c,
        &[
            "static final useForm = (WidgetRef ref, {ActionFormValidation validation",
            "data: null, initial: () => _i1.form(), ",
            "starting from `form()`;",
        ],
    );
    lacks(&c, &["required Profile data"]);
}

#[test]
fn form_hook_of_a_keyed_action_takes_the_keys() {
    let c = code(&[
        ("page.dart", HOME),
        (
            "orders/$id/page.dart",
            "class OrderPage extends StatelessWidget { const OrderPage({super.key, required this.id}); final int id; }",
        ),
        (
            "orders/$id/action.dart",
            "typedef F = ({String note});\nF form() => (note: '');\nFuture<void> action(Ref ref, {required int id, required F input}) async {}\n",
        ),
    ]);
    has(
        &c,
        &[
            "static final useForm = (WidgetRef ref, {required int id, ActionFormValidation validation",
            "useActionForm(ref, action(id), data: null,",
        ],
    );
}

#[test]
fn form_data_type_is_shown_from_action_imports() {
    let c = code(&nickname(&format!(
        "import '../models.dart';\n{FIELDS}{FORM}{ACTION}"
    )));
    has(&c, &["import 'app/models.dart' show Profile;"]);
}

#[test]
fn optimistic_targets_nearest_matching_data() {
    // The folder's own data wins over a section above that gives the same type.
    let c = code(&[
        ("page.dart", HOME),
        ("(a)/data.dart", "Future<Profile> data(Ref ref) async => x;"),
        (
            "(a)/layout.dart",
            &widget(
                "ALayout",
                "final Widget child; final Profile outer;",
                ", required this.child, required this.outer",
            ),
        ),
        (
            "(a)/nickname/page.dart",
            "class NicknamePage extends StatelessWidget { const NicknamePage({super.key, required this.data}); final Profile data; }",
        ),
        ("(a)/nickname/data.dart", PROFILE_DATA),
        (
            "(a)/nickname/action.dart",
            &format!("{FIELDS}{OPTIMISTIC}{ACTION}"),
        ),
    ]);
    has(
        &c,
        &["optimistic: () => _optimistic2.patch(_i4.optimistic),"],
    );
    lacks(&c, &["_optimistic1"]);
}

#[test]
fn optimistic_on_section_data_patches_every_read_site() {
    let files = [
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
            "class MembersPage extends StatelessWidget { const MembersPage({super.key, required this.team, required this.teamId}); final Team team; final String teamId; }",
        ),
        (
            "teams/$teamId/action.dart",
            "Team addMemberOptimistic(Team team, String input) => team;\nFuture<void> addMember(Ref ref, {required String teamId, required String input}) async {}\n",
        ),
    ];
    let c = code(&files);
    has(
        &c,
        &[
            // The layout's DataView and the page's SectionView.
            "optimistic: (ref) => ref.watch(_optimistic2(v.teamId)),",
            "SectionView(",
            // The typed handle.
            "static final watch = (WidgetRef ref, {required String teamId}) => ref.watchOptimistic(data(teamId), _optimistic2(teamId));",
            // The layer and the action.
            "final _optimistic2 = optimisticLayerFamily((String teamId) => _data2(teamId));",
            "optimistic: (String teamId) => _optimistic2(teamId).patch(_i2.addMemberOptimistic),",
        ],
    );
    assert_eq!(c.matches("ref.watch(_optimistic2(v.teamId))").count(), 2);
}

#[test]
fn layer_is_shared_by_actions_patching_the_same_data() {
    let c = code(&nickname(&format!(
        "{FIELDS}{OPTIMISTIC}{ACTION}\
         Profile renameOptimistic(Profile current, String input) => current;\n\
         Future<void> rename(Ref ref, {{required String input}}) async {{}}\n"
    )));
    assert_eq!(c.matches("final _optimistic1 = ").count(), 1);
    has(
        &c,
        &[
            "(`optimistic()` of nickname/action.dart, `renameOptimistic()` of nickname/action.dart)",
            "optimistic: () => _optimistic1.patch(_i2.optimistic),",
            "optimistic: () => _optimistic1.patch(_i2.renameOptimistic),",
        ],
    );
}

#[test]
fn a_family_layer_is_keyed_by_a_record_of_keys() {
    let c = code(&[
        ("page.dart", HOME),
        (
            "shops/$shop/items/$id/page.dart",
            "class ItemPage extends StatelessWidget { const ItemPage({super.key, required this.shop, required this.id, required this.item}); final String shop; final int id; final Item item; }",
        ),
        (
            "shops/$shop/items/$id/data.dart",
            "Future<Item> data(Ref ref, {required String shop, required int id}) async => x;",
        ),
        (
            "shops/$shop/items/$id/action.dart",
            "Item optimistic(Item item, String input) => item;\nFuture<void> action(Ref ref, {required String shop, required int id, required String input}) async {}\n",
        ),
    ]);
    has(
        &c,
        &[
            "final _optimistic4 = optimisticLayerFamily((({String shop, int id}) k) => _data4((shop: k.shop, id: k.id)));",
            "optimistic: (({String shop, int id}) k) => _optimistic4((shop: k.shop, id: k.id)).patch(_i2.optimistic),",
            "optimistic: (ref) => ref.watch(_optimistic4((shop: v.shop, id: v.id))),",
        ],
    );
}

// --- diagnostics ---------------------------------------------------------------------------

#[test]
fn f1_a_form_takes_no_ref() {
    action_error(
        &format!("{FIELDS}NicknameFields form(Ref ref, Profile profile) => x;\n{ACTION}"),
        2,
        "`form()` is the form of `action()`: it gives the form its first values from the data the page passes, so it takes that value (or nothing), not a `Ref`",
    );
}

#[test]
fn f1_a_function_called_form_beside_action_is_the_companion() {
    // In 0.7.0 this was a second action: it is now the form, and says so.
    action_error(
        &format!(
            "{FIELDS}Future<void> form(Ref ref, {{required NicknameFields input}}) async {{}}\n{ACTION}"
        ),
        2,
        "`form()` is the form of `action()`: it gives the form its first values from the data the page passes, so it takes that value (or nothing), not a `Ref`",
    );
}

#[test]
fn f2_a_form_needs_a_return_type() {
    action_error(
        &format!("{FIELDS}form(Profile profile) => x;\n{ACTION}"),
        2,
        "`form()` needs an explicit return type: the input of `action()`, `NicknameFields`",
    );
}

#[test]
fn f3_a_form_returns_the_input_type() {
    action_error(
        &format!("{FIELDS}Object form(Profile profile) => x;\n{ACTION}"),
        2,
        "`form()` returns `Object`, but `action()` takes `NicknameFields` as `input`: the form builds the action's input, so they are the same type",
    );
}

#[test]
fn f4a_the_input_must_be_a_record_declared_here() {
    let msg = "the form of `action()` needs the fields of its input, and `String` is not a record type declared here: take `input` as a record with named fields (`required ({int amount, String note}) input`), or as a typedef of one declared in action.dart";
    action_error(
        "String form(Profile profile) => x;\nFuture<void> action(Ref ref, {required String input}) async {}\n",
        1,
        msg,
    );
    // A typedef that is not declared in this file is not read.
    let msg = "the form of `action()` needs the fields of its input, and `Fields` is not a record type declared here: take `input` as a record with named fields (`required ({int amount, String note}) input`), or as a typedef of one declared in action.dart";
    action_error(
        "Fields form(Profile profile) => x;\nFuture<void> action(Ref ref, {required Fields input}) async {}\n",
        1,
        msg,
    );
}

#[test]
fn f4b_the_fields_must_be_named() {
    action_error(
        "(int, String) form(Profile profile) => x;\nFuture<void> action(Ref ref, {required (int, String) input}) async {}\n",
        1,
        "the form of `action()` needs a name for each field of its input, and `(int, String)` has positional fields: name them, e.g. `({int amount, String note})`",
    );
}

#[test]
fn f5_a_form_takes_one_positional_parameter_at_most() {
    let msg = "`form()` takes at most one parameter, positional and required: the value the form starts from, which the page passes to `useForm` as `data:`";
    action_error(
        &format!("{FIELDS}NicknameFields form(Profile a, Profile b) => x;\n{ACTION}"),
        2,
        msg,
    );
    action_error(
        &format!("{FIELDS}NicknameFields form({{required Profile profile}}) => x;\n{ACTION}"),
        2,
        msg,
    );
}

#[test]
fn f6_the_data_parameter_has_a_type() {
    action_error(
        &format!("{FIELDS}NicknameFields form(profile) => x;\n{ACTION}"),
        2,
        "give the parameter of `form()` a type: it is the type of `data:` in `useForm`",
    );
}

#[test]
fn a_key_cannot_take_the_name_of_a_form_hook_parameter() {
    let e = error(&[
        ("page.dart", HOME),
        (
            "x/$messages/page.dart",
            "class XPage extends StatelessWidget { const XPage({super.key, required this.messages}); final String messages; }",
        ),
        (
            "x/$messages/action.dart",
            "typedef F = ({String note});\nF form() => (note: '');\nFuture<void> action(Ref ref, {required String messages, required F input}) async {}\n",
        ),
    ]);
    assert_eq!(
        e,
        "✗ x/$messages/action.dart:3  `messages` can't be a key of an action with a form: its hook, `useForm`, takes a parameter called `messages`; rename it"
    );
}

#[test]
fn v1_a_validation_takes_no_ref() {
    action_error(
        &format!("{FIELDS}FieldErrors? validate(Ref ref, NicknameFields input) => null;\n{ACTION}"),
        2,
        "`validate()` is the validation of `action()`: it runs on the device before the action, with the input alone, so it takes no `Ref`; a check that needs the server belongs in `action()`, which throws `FieldErrors`",
    );
}

#[test]
fn v2_a_validation_takes_the_input_and_returns_field_errors() {
    let msg = "expected `FieldErrors? validate(NicknameFields input)`: the validation of `action()` takes the action's input and returns what is wrong with it, or null";
    action_error(
        &format!("{FIELDS}String? validate(NicknameFields input) => null;\n{ACTION}"),
        2,
        msg,
    );
    action_error(
        &format!("{FIELDS}FieldErrors? validate(Object input) => null;\n{ACTION}"),
        2,
        msg,
    );
}

#[test]
fn a_validation_needs_no_record_input() {
    let c = code(&[
        ("page.dart", HOME),
        ("nickname/page.dart", &widget("NicknamePage", "", "")),
        (
            "nickname/action.dart",
            "FieldErrors? validate(String input) => null;\nFuture<void> action(Ref ref, {required String input}) async {}\n",
        ),
    ]);
    has(&c, &["  validate: _i1.validate,\n"]);
}

#[test]
fn o1_an_optimistic_patch_takes_no_ref() {
    action_error(
        &format!(
            "{FIELDS}Profile optimistic(Ref ref, Profile current, NicknameFields input) => current;\n{ACTION}"
        ),
        2,
        "`optimistic()` is the optimistic patch of `action()`: it runs while the page builds, with the value the page shows and the input, so it takes no `Ref`",
    );
}

#[test]
fn o2_an_optimistic_patch_takes_the_value_and_the_input() {
    let msg = "expected `T optimistic(T current, NicknameFields input)`: the optimistic patch of `action()` takes the value of a data.dart it invalidates and the input, and returns the value to show while the write is in flight";
    // Returns another type than it takes.
    action_error(
        &format!(
            "{FIELDS}String optimistic(Profile current, NicknameFields input) => '';\n{ACTION}"
        ),
        2,
        msg,
    );
    // The input is not the action's.
    action_error(
        &format!("{FIELDS}Profile optimistic(Profile current, String input) => current;\n{ACTION}"),
        2,
        msg,
    );
    // One parameter.
    action_error(
        &format!("{FIELDS}Profile optimistic(Profile current) => current;\n{ACTION}"),
        2,
        msg,
    );
}

#[test]
fn o3a_the_patched_type_must_be_given_by_what_the_action_invalidates() {
    action_error(
        &format!(
            "{FIELDS}Order optimistic(Order current, NicknameFields input) => current;\n{ACTION}"
        ),
        2,
        "`optimistic()` patches a `Order`, and no data.dart that `action()` invalidates gives one (`nickname/data.dart` gives `Profile`): patch the type of one of them, or list the route whose data.dart gives a `Order` in `invalidates`",
    );
}

#[test]
fn o3b_an_action_that_invalidates_nothing_patches_nothing() {
    action_error(
        &format!("const invalidates = <Object>[];\n{FIELDS}{OPTIMISTIC}{ACTION}"),
        3,
        "`optimistic()` patches a `Profile`, but `action()` invalidates no data.dart: list the route whose data.dart gives a `Profile` in `invalidates`",
    );
}

#[test]
fn w1_a_companion_with_a_plain_name_and_no_action_is_a_warning() {
    let d = diags(&[
        ("page.dart", HOME),
        ("nickname/page.dart", &widget("NicknamePage", "", "")),
        (
            "nickname/action.dart",
            "bool validate(String s) => true;\nFuture<void> approve(Ref ref, {required String input}) async {}\n",
        ),
    ]);
    assert_eq!(
        d,
        [
            "! nickname/action.dart:1  `validate()` would be the validation of `action()`, and action.dart has no `action()`: name it after the action it belongs to (`<action>Validate`, e.g. `approveValidate` for `approve()`), or make it private"
        ]
    );
    // A name with a prefix is just a helper.
    let d = diags(&[
        ("page.dart", HOME),
        ("nickname/page.dart", &widget("NicknamePage", "", "")),
        (
            "nickname/action.dart",
            "bool xForm(String s) => true;\nFuture<void> approve(Ref ref, {required String input}) async {}\n",
        ),
    ]);
    assert!(d.is_empty(), "{d:?}");
}

#[test]
fn form_hook_name_collides() {
    // `useForm` is also what an action called `form` would get: it is a companion now, so the
    // collision that can still happen is with a segment or query parameter.
    let e = error(&[
        ("page.dart", HOME),
        (
            "x/$useForm/page.dart",
            "class XPage extends StatelessWidget { const XPage({super.key, required this.useForm}); final String useForm; }",
        ),
        (
            "x/$useForm/action.dart",
            "typedef F = ({String note});\nF form() => (note: '');\nFuture<void> action(Ref ref, {required String useForm, required F input}) async {}\n",
        ),
    ]);
    assert!(
        e.contains("the form hook of action() would be called `useForm`, which is already `useForm`, a segment or query parameter of the route; rename the function"),
        "{e}"
    );
}

// --- the fespalier_forms package (since 0.11.0) -------------------------------------------------

/// The files built with a pubspec that lists (or not) `fespalier_forms`, through `Config::load`.
fn with_pubspec(pubspec: &str, files: &[(&str, &str)]) -> (String, Vec<String>) {
    let dir = crate::action_tests::project(files);
    std::fs::write(dir.path().join("pubspec.yaml"), pubspec).unwrap();
    let cfg = crate::config::Config::load(dir.path()).unwrap();
    let (code, diags, _) = crate::build(&dir.path().join("lib/app"), &cfg).unwrap();
    let errors = diags
        .0
        .iter()
        .map(ToString::to_string)
        .filter(|d| d.starts_with('✗'))
        .collect();
    (code, errors)
}

const WITH_PACKAGE: &str = "name: demo\ndependencies:\n  fespalier:\n    path: ../fespalier\n  fespalier_forms:\n    path: ../fespalier_forms\n";
const WITHOUT_PACKAGE: &str = "name: demo\ndependencies:\n  fespalier:\n    path: ../fespalier\n";

#[test]
fn the_generated_file_imports_the_forms_package_when_an_action_has_a_form() {
    let c = code(&nickname(&all()));
    has(
        &c,
        &["import 'package:fespalier_forms/fespalier_forms.dart';\n"],
    );
    // After fespalier's own, before Flutter's.
    let at = |s: &str| c.find(s).unwrap();
    assert!(
        at("import 'package:fespalier/fespalier.dart';")
            < at("import 'package:fespalier_forms/fespalier_forms.dart';")
            && at("import 'package:fespalier_forms/fespalier_forms.dart';")
                < at("import 'package:flutter/widgets.dart';")
    );
}

#[test]
fn an_app_without_a_form_does_not_import_it() {
    let c = code(&nickname(&format!("{FIELDS}{VALIDATE}{ACTION}")));
    lacks(&c, &["fespalier_forms"]);
    let c = code(&[("page.dart", HOME)]);
    lacks(&c, &["fespalier_forms"]);
}

#[test]
fn a_form_needs_the_forms_package_in_the_pubspec() {
    let (code, errors) = with_pubspec(WITH_PACKAGE, &nickname(&all()));
    assert!(errors.is_empty(), "{errors:?}");
    has(
        &code,
        &["import 'package:fespalier_forms/fespalier_forms.dart';"],
    );

    let (_, errors) = with_pubspec(WITHOUT_PACKAGE, &nickname(&all()));
    assert_eq!(
        errors,
        [format!(
            "✗ nickname/action.dart:2  {}",
            crate::forms::missing_package("form", "action")
        )]
    );
    assert_eq!(
        crate::forms::missing_package("form", "action"),
        "`form()` is the form of `action()`, and since 0.11.0 forms are in the fespalier_forms package: add `fespalier_forms` under `dependencies:` in pubspec.yaml, with the same git `url` and `ref` as fespalier"
    );
}

#[test]
fn an_action_without_a_form_needs_no_package() {
    let (code, errors) = with_pubspec(
        WITHOUT_PACKAGE,
        &nickname(&format!("{FIELDS}{VALIDATE}{OPTIMISTIC}{ACTION}")),
    );
    assert!(errors.is_empty(), "{errors:?}");
    lacks(&code, &["fespalier_forms"]);
}

#[test]
fn every_form_of_an_app_is_reported() {
    let action = "typedef F = ({String note});\nF form() => (note: '');\nFuture<void> action(Ref ref, {required F input}) async {}\n";
    let (_, errors) = with_pubspec(
        WITHOUT_PACKAGE,
        &[
            ("page.dart", HOME),
            ("a/page.dart", &widget("APage", "", "")),
            ("a/action.dart", action),
            ("b/page.dart", &widget("BPage", "", "")),
            ("b/action.dart", action),
        ],
    );
    assert_eq!(errors.len(), 2, "{errors:?}");
}
