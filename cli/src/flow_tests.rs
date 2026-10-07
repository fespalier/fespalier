//! Multi-page forms (since 0.11.0): a section's `action.dart` with `const steps`. The generator
//! reads the steps, declares their enum, emits `useFlow`, `flowOf` and `resume` on the section's
//! handle, applies the section's page-less `leave.dart` to each step with `within:`, tags the steps
//! `flow` and reports what is wrong with the map.

use std::fs;

use crate::action_tests::{HOME, code, errors, has, lacks};
use crate::config::Config;
use crate::{analyze, routes};

const LAYOUT: &str = "class SignupLayout extends StatelessWidget { const SignupLayout({super.key, required this.child}); final Widget child; }";
const LEAVE: &str = "import 'package:fespalier/fespalier.dart';\nLeaveResult leave(BuildContext context, Ref ref, {required PageLeave page}) => true;\n";
const GUARD: &str = "import 'package:fespalier/fespalier.dart';\nGuardResult guard(Ref ref, {required Uri uri}) => null;\n";

fn step_page(name: &str) -> (String, String) {
    let class = format!(
        "class Signup{}Page extends StatelessWidget {{ const Signup{}Page({{super.key}}); }}",
        capital(name),
        capital(name)
    );
    (format!("signup/{name}/page.dart"), class)
}

fn capital(s: &str) -> String {
    let mut c = s.chars();
    c.next()
        .map(|f| f.to_uppercase().chain(c).collect())
        .unwrap_or_default()
}

const FIELDS: &str = "typedef SignupFields = ({String name, bool business, String? company, String email, String? phone});\n";
const FORM: &str =
    "SignupFields form() => (name: '', business: false, company: null, email: '', phone: null);\n";
const STEPS: &str = "const steps = {\n  'name': ['name', 'business'],\n  'company': ['company'],\n  'contact': ['email', 'phone'],\n  'review': <String>[],\n};\n";
const SKIP: &str = "bool skip(SignupStep step, SignupFields input) => step == SignupStep.company && !input.business;\n";
const VALIDATE: &str = "FieldErrors? validate(SignupFields input) => null;\n";
const ACTION: &str = "Future<Account> action(Ref ref, {required SignupFields input}) async => x;\n";

fn action_file(parts: &[&str]) -> String {
    parts.concat()
}

fn all() -> String {
    action_file(&[FIELDS, FORM, STEPS, SKIP, VALIDATE, ACTION])
}

/// The files of the signup section: layout, the four steps and the action.dart given. `extra` are
/// more files (leave.dart, guard.dart).
fn signup(action: &str, extra: &[(&str, &str)]) -> Vec<(String, String)> {
    let mut files = vec![
        ("page.dart".to_string(), HOME.to_string()),
        ("signup/layout.dart".to_string(), LAYOUT.to_string()),
        ("signup/action.dart".to_string(), action.to_string()),
    ];
    for s in ["name", "company", "contact", "review"] {
        files.push(step_page(s));
    }
    files.extend(extra.iter().map(|(a, b)| (a.to_string(), b.to_string())));
    files
}

fn refs(files: &[(String, String)]) -> Vec<(&str, &str)> {
    files
        .iter()
        .map(|(a, b)| (a.as_str(), b.as_str()))
        .collect()
}

fn flow_code(action: &str, extra: &[(&str, &str)]) -> String {
    code(&refs(&signup(action, extra)))
}

/// The one error line these files give, for a message `contains` check.
fn error(files: &[(String, String)]) -> String {
    let e = errors(&refs(files));
    assert_eq!(e.lines().count(), 1, "{e}");
    e
}

fn action_error(action: &str, msg: &str) {
    let e = error(&signup(action, &[]));
    assert!(e.starts_with("✗ signup/action.dart:"), "{e}");
    assert!(e.ends_with(&format!("  {msg}")), "{e}");
}

// ---- what is generated ----

#[test]
fn the_steps_are_an_enum_and_the_section_gets_the_flow_members() {
    let c = flow_code(&all(), &[("signup/leave.dart", LEAVE)]);
    has(
        &c,
        &[
            "/// The steps of the form of signup/action.dart, in order: each is a child folder of the section with a page.dart (since 0.11.0).\nenum SignupStep {\n  /// `name/page.dart`\n  name,\n  /// `company/page.dart`\n  company,\n  /// `contact/page.dart`\n  contact,\n  /// `review/page.dart`\n  review;\n}",
            "abstract final class SignupSection {",
            "static final _flow = FlowSpec(",
            "id: 'signup/action.dart#action',",
            "shape: 'name:String,business:bool,company:String?,email:String,phone:String?',",
            "steps: SignupStep.values,",
            "routes: {SignupStep.name: const SignupNameRoute(), SignupStep.company: const SignupCompanyRoute(), SignupStep.contact: const SignupContactRoute(), SignupStep.review: const SignupReviewRoute()},",
            "owners: const {'name': SignupStep.name, 'business': SignupStep.name, 'company': SignupStep.company, 'email': SignupStep.contact, 'phone': SignupStep.contact},",
            ".skip,",
            "fields: (ActionFormFields<_i1.SignupFields> f) => (name: f.text('name', (v) => v.name, FieldCodec.text), business: f.value('business', (v) => v.business, draft: DraftCodec.boolean), company: f.text('company', (v) => v.company, FieldCodec.optionalText), email: f.text('email', (v) => v.email, FieldCodec.text), phone: f.text('phone', (v) => v.phone, FieldCodec.optionalText)),",
            "input: (f) => (name: f.name.value, business: f.business.value, company: f.company.value, email: f.email.value, phone: f.phone.value),",
            ".validate,",
            "static final useFlow = (WidgetRef ref, {ActionFormValidation validation = ActionFormValidation.afterSubmit, FormDraft? draft = const FormDraft(), ActionFormMessages messages = const ActionFormMessages()}) => _flow.use(ref, action, validation: validation, draft: draft, messages: messages);",
            "static final flowOf = (BuildContext context) => _flow.of(context);",
            "static GuardResult resume(Ref ref, {required Uri uri}) => _flow.resume(ref, uri: uri);",
        ],
    );
    // A flow has its own hook, not a form's, and the file imports the package.
    lacks(&c, &["useForm", "useActionForm"]);
    has(
        &c,
        &["import 'package:fespalier_forms/fespalier_forms.dart';"],
    );
}

#[test]
fn a_flow_without_skip_passes_none() {
    let c = flow_code(
        &action_file(&[FIELDS, FORM, STEPS, ACTION]),
        &[("signup/leave.dart", LEAVE)],
    );
    has(&c, &["static final _flow = FlowSpec("]);
    lacks(&c, &["skip:", ".skip"]);
}

#[test]
fn a_named_action_gets_named_members_and_its_own_enum() {
    let c = flow_code(
        &action_file(&[
            FIELDS,
            "SignupFields enrollForm() => (name: '', business: false, company: null, email: '', phone: null);\n",
            &STEPS.replace("const steps", "const enrollSteps"),
            "bool enrollSkip(SignupEnrollStep step, SignupFields input) => false;\n",
            "Future<Account> enroll(Ref ref, {required SignupFields input}) async => x;\n",
        ]),
        &[],
    );
    has(
        &c,
        &[
            "enum SignupEnrollStep {",
            "static final _enrollFlow = FlowSpec(",
            "steps: SignupEnrollStep.values,",
            "static final useEnrollFlow = (WidgetRef ref,",
            "_enrollFlow.use(ref, enrollAction,",
            "static final enrollFlowOf = (BuildContext context) => _enrollFlow.of(context);",
            "static GuardResult enrollResume(Ref ref, {required Uri uri}) => _enrollFlow.resume(ref, uri: uri);",
        ],
    );
    lacks(&c, &["useEnrollForm"]);
}

#[test]
fn each_step_is_asked_by_the_sections_leave_with_within() {
    let c = flow_code(&all(), &[("signup/leave.dart", LEAVE)]);
    for step in ["name", "company", "contact", "review"] {
        has(&c, &[&format!("path: '/signup/{step}',")]);
    }
    assert_eq!(
        c.matches("onExit: (context, state) => leaveExit(context, state, 'signup/leave.dart', (ref, page) => _i")
            .count(),
        4,
        "{c}"
    );
    assert_eq!(
        c.matches("(context, ref, page: page), within: joinLocation(at, '/signup')),")
            .count(),
        4,
        "{c}"
    );
    // Each step's page wears leaveScope and flowStep; the layout's shell has no onExit of its own.
    assert_eq!(c.matches("leaveScope(state, flowStep(").count(), 4, "{c}");
}

#[test]
fn a_flow_with_no_leave_has_no_on_exit_and_no_scope() {
    let c = flow_code(&all(), &[]);
    lacks(&c, &["leaveExit", "onExit", "within:"]);
    // Every step still has the flow in its page scope, so the system back goes to the previous step.
    assert_eq!(c.matches("leaveScope(state, flowStep(").count(), 4, "{c}");
    // The guard of the section is the app's own: `resume` is what it calls.
    let c = flow_code(&all(), &[("signup/guard.dart", GUARD)]);
    has(&c, &["static GuardResult resume("]);
}

#[test]
fn a_page_less_folder_that_is_no_flow_keeps_the_error() {
    let files = [
        ("page.dart", HOME),
        ("signup/layout.dart", LAYOUT),
        (
            "signup/name/page.dart",
            "class SignupNamePage extends StatelessWidget { const SignupNamePage({super.key}); }",
        ),
        (
            "signup/action.dart",
            "Future<int> action(Ref ref, {required ({int a}) input}) async => 1;\n",
        ),
        ("signup/leave.dart", LEAVE),
    ];
    let e = errors(&files);
    assert_eq!(
        e,
        "✗ signup/leave.dart  leave.dart is asked before this folder's page goes, and this folder has no page.dart (a layout's shell has no onExit in go_router: put a leave.dart beside each page that needs one)"
    );
}

#[test]
fn the_steps_are_tagged_flow_in_the_route_table_and_the_json() {
    let dir = crate::action_tests::project(&refs(&signup(&all(), &[("signup/leave.dart", LEAVE)])));
    let (_, diags, app) = analyze(&dir.path().join("lib/app"), &Config::default()).unwrap();
    assert!(diags.0.is_empty(), "{:?}", diags.0);
    let rows = routes::table(&app);
    for step in ["name", "company", "contact", "review"] {
        let row = rows
            .iter()
            .find(|r| r.contains(&format!("signup/{step}/page.dart")))
            .unwrap_or_else(|| panic!("{rows:?}"));
        assert!(row.contains("flow"), "{row}");
        assert!(row.contains("leave"), "{row}");
    }
    let home = rows.iter().find(|r| r.contains("  page.dart")).unwrap();
    assert!(!home.contains("flow"), "{home}");
    let json = routes::json_lines(&app, "lib/app");
    assert_eq!(
        json.iter().filter(|l| l.contains("\"flow\"")).count(),
        4,
        "{json:?}"
    );
    let g = crate::graph::render(&app, &Config::default(), crate::graph::Format::Json);
    assert!(g.contains("\"flow\""), "{g}");
}

#[test]
fn a_step_with_no_leave_is_still_tagged() {
    let dir = crate::action_tests::project(&refs(&signup(&all(), &[])));
    let (_, _, app) = analyze(&dir.path().join("lib/app"), &Config::default()).unwrap();
    let json = routes::json_lines(&app, "lib/app");
    assert_eq!(
        json.iter().filter(|l| l.contains("\"flow\"")).count(),
        4,
        "{json:?}"
    );
}

#[test]
fn the_package_is_required_like_any_form() {
    let files = signup(&all(), &[]);
    let dir = crate::action_tests::project(&refs(&files));
    fs::write(
        dir.path().join("pubspec.yaml"),
        "name: demo\ndependencies:\n  fespalier:\n    path: ../fespalier\n",
    )
    .unwrap();
    let cfg = Config::load(dir.path()).unwrap();
    let (_, diags, _) = crate::build(&dir.path().join("lib/app"), &cfg).unwrap();
    let e: Vec<String> = diags.0.iter().map(ToString::to_string).collect();
    assert_eq!(e.len(), 1, "{e:?}");
    assert!(
        e[0].ends_with(&crate::forms::missing_package("form", "action")),
        "{e:?}"
    );
}

// ---- diagnostics ----

#[test]
fn steps_must_be_a_const_map_of_lists() {
    let msg = "`steps` must be a `const` map literal from a step folder's name to the list of the input's fields it asks for, in order";
    for steps in [
        "final steps = {'name': ['name']};\n",
        "const steps = {'name': 'name'};\n",
        "const steps = {};\n",
        "const steps = {'name': ['name'], 'name': ['email']};\n",
    ] {
        action_error(&action_file(&[FIELDS, FORM, steps, ACTION]), msg);
    }
}

#[test]
fn a_steps_that_is_no_map_is_the_apps_own() {
    for steps in [
        "const steps = 3;\n",
        "const steps = ['name'];\n",
        "final steps = <String>[];\n",
    ] {
        let c = flow_code(&action_file(&[FIELDS, FORM, steps, ACTION]), &[]);
        lacks(&c, &["FlowSpec", "enum SignupStep"]);
        has(&c, &["static final useForm = "]);
    }
}

#[test]
fn a_step_has_no_leave_of_its_own() {
    let leave_step = ("signup/name/leave.dart", LEAVE);
    let files = signup(&all(), &[("signup/leave.dart", LEAVE), leave_step]);
    let e = error(&files);
    assert_eq!(
        e,
        "✗ signup/name/leave.dart  a step of a flow is asked by the section's leave.dart: remove this one (a navigation inside signup is never asked, and leaving it is asked once, by the section's leave.dart)"
    );
    // Also when the section has none: the step's would be dropped.
    let files = signup(&all(), &[leave_step]);
    assert!(error(&files).starts_with("✗ signup/name/leave.dart  a step of a flow"));
}

#[test]
fn steps_make_the_action_a_sections() {
    let mut files = signup(&all(), &[]);
    files.push((
        "signup/page.dart".into(),
        "class SignupPage extends StatelessWidget { const SignupPage({super.key}); }".into(),
    ));
    let e = error(&files);
    assert!(e.starts_with("✗ signup/action.dart:"), "{e}");
    assert!(
        e.ends_with("  `steps` makes `action()` a form over several pages, so action.dart must be a section's: a folder with a layout.dart and no page.dart"),
        "{e}"
    );
}

#[test]
fn a_step_is_a_child_folder_with_a_page() {
    for step in ["missing", "name/deeper"] {
        let steps = format!(
            "const steps = {{'{step}': ['name', 'business', 'company', 'email', 'phone']}};\n"
        );
        action_error(
            &action_file(&[FIELDS, FORM, &steps, ACTION]),
            &format!(
                "`'{step}'` is a step, but `signup/{step}/page.dart` does not exist: each step is a child folder with a page.dart"
            ),
        );
    }
}

#[test]
fn a_step_asks_for_fields_of_the_input() {
    let steps = STEPS.replace("'phone'", "'phone', 'nickname'");
    action_error(
        &action_file(&[FIELDS, FORM, &steps, ACTION]),
        "`'nickname'` is not a field of `SignupFields`",
    );
}

#[test]
fn a_field_belongs_to_one_step() {
    let steps = STEPS.replace("['company']", "['company', 'email']");
    action_error(
        &action_file(&[FIELDS, FORM, &steps, ACTION]),
        "`'email'` is asked for by `'company'` and `'contact'`: a field belongs to one step",
    );
}

#[test]
fn a_field_with_no_step_is_reported() {
    let steps = STEPS.replace("['email', 'phone']", "['email']");
    action_error(
        &action_file(&[FIELDS, FORM, &steps, ACTION]),
        "`'phone'` belongs to no step: add it to the step that asks for it",
    );
}

#[test]
fn steps_start_from_a_form() {
    action_error(
        &action_file(&[FIELDS, STEPS, ACTION]),
        "`steps` without `form()`: a flow starts from `form()`",
    );
}

#[test]
fn skip_has_a_signature() {
    for skip in [
        "bool skip(String step, SignupFields input) => false;\n",
        "bool skip(SignupStep step) => false;\n",
        "int skip(SignupStep step, SignupFields input) => 0;\n",
    ] {
        action_error(
            &action_file(&[FIELDS, FORM, STEPS, skip, ACTION]),
            "expected `bool skip(SignupStep step, SignupFields input)` (`<name>Skip` for an action called `<name>`)",
        );
    }
}

#[test]
fn a_key_called_draft_is_reserved_for_the_flow_hook() {
    // The section's own segment is a key of its action: `draft` is a parameter of `useFlow`.
    let files = vec![
        ("page.dart".to_string(), HOME.to_string()),
        ("signup/$draft/layout.dart".to_string(), LAYOUT.to_string()),
        (
            "signup/$draft/action.dart".to_string(),
            action_file(&[
                FIELDS,
                FORM,
                STEPS,
                "Future<Account> action(Ref ref, {required int draft, required SignupFields input}) async => x;\n",
            ]),
        ),
    ];
    let e = errors(&refs(&files));
    assert!(
        e.contains("`draft` can't be a key of an action with a form: its hook, `useFlow`, takes a parameter called `draft`; rename it"),
        "{e}"
    );
}

#[test]
fn a_flow_does_not_take_a_value() {
    action_error(
        &action_file(&[
            FIELDS,
            "SignupFields form(Account account) => (name: '', business: false, company: null, email: '', phone: null);\n",
            STEPS,
            ACTION,
        ]),
        "`form()` can't take a value in a flow: `resume` runs in a guard, before any data is loaded, and builds the form from `form()` alone",
    );
}

#[test]
fn a_flow_does_not_sit_under_a_dynamic_segment() {
    let files = vec![
        ("page.dart".to_string(), HOME.to_string()),
        (
            "teams/$id/signup/layout.dart".to_string(),
            LAYOUT.to_string(),
        ),
        ("teams/$id/signup/action.dart".to_string(), all()),
        step_page_in("teams/$id/signup", "name"),
        step_page_in("teams/$id/signup", "company"),
        step_page_in("teams/$id/signup", "contact"),
        step_page_in("teams/$id/signup", "review"),
    ];
    let e = errors(&refs(&files));
    assert!(
        e.contains("a flow sits at a path with no dynamic segment for now: its steps are `go`ne to by their typed routes, and `id` would have to be given to each"),
        "{e}"
    );
}

fn step_page_in(dir: &str, name: &str) -> (String, String) {
    (
        format!("{dir}/{name}/page.dart"),
        format!(
            "class Signup{}Page extends StatelessWidget {{ const Signup{}Page({{super.key}}); }}",
            capital(name),
            capital(name)
        ),
    )
}

#[test]
fn a_flow_does_not_sit_inside_another() {
    let inner = action_file(&[
        "typedef InnerFields = ({String a});\n",
        "InnerFields form() => (a: '');\n",
        "const steps = {'one': ['a']};\n",
        "Future<int> action(Ref ref, {required InnerFields input}) async => 1;\n",
    ]);
    let mut files = signup(&all(), &[]);
    files.push(("signup/name/inner/layout.dart".into(), LAYOUT.into()));
    files.push(("signup/name/inner/action.dart".into(), inner));
    files.push((
        "signup/name/inner/one/page.dart".into(),
        "class InnerOnePage extends StatelessWidget { const InnerOnePage({super.key}); }".into(),
    ));
    let e = errors(&refs(&files));
    assert!(
        e.contains("a flow can't sit inside another flow: this section is below the flow of signup/action.dart; flows are one level, and a step is a page that holds no flow of its own"),
        "{e}"
    );
}

#[test]
fn a_flows_leave_reads_no_url_parameter() {
    let leave = "import 'package:fespalier/fespalier.dart';\nLeaveResult leave({int? page, required PageLeave leaving}) => true;\n";
    let files = signup(&all(), &[("signup/leave.dart", leave)]);
    let e = errors(&refs(&files));
    assert!(
        e.contains("a flow's leave() is asked on every step of the section, so it reads no segment, query parameter or `extra`: `Uri uri` has the location"),
        "{e}"
    );
}

#[test]
fn a_flow_leave_can_read_the_uri() {
    let leave = "import 'package:fespalier/fespalier.dart';\nLeaveResult leave(Ref ref, {required Uri uri, required PageLeave page}) => true;\n";
    let c = flow_code(&all(), &[("signup/leave.dart", leave)]);
    has(
        &c,
        &[
            "(ref, page) => _i",
            ".leave(ref, uri: state.uri, page: page), within: joinLocation(at, '/signup')),",
        ],
    );
}
