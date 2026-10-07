# Multi-page forms: flows (since 0.11.0)

A form over several pages: the steps are pages of a section, they share **one form and one draft**, and the
question about unsaved changes is asked **once**, when the user leaves the flow. It is `fespalier_forms`'
`FormFlow`, an [`ActionForm`](forms.md) that the section's layout owns. An app on 0.10.0 or earlier has none of
this. Runtime: `packages/fespalier_forms/lib/src/form_flow.dart`; the generator's side is `steps_flow` in
`cli/src/resolve.rs` and `flow_cx` in `cli/src/emit.rs`; the user documentation is `docs/forms.md`, "Multi-page
forms".

## Declare it

A flow is a **section**: a folder with a `layout.dart` and no `page.dart`, with an `action.dart` whose `form()` gains
`const steps`. Each step is a **direct** child folder with a `page.dart`.

```dart
// lib/app/signup/action.dart
typedef SignupFields = ({String name, bool business, String? company, String email});

SignupFields form() => (name: '', business: false, company: null, email: '');

const steps = {
  'name': ['name', 'business'],
  'company': ['company'],
  'contact': ['email'],
  'review': <String>[],
};

bool skip(SignupStep step, SignupFields input) => step == SignupStep.company && !input.business; // optional

FieldErrors? validate(SignupFields input) => FieldErrors({if (input.name.isEmpty) 'name': 'Enter your name'});

Future<Account> action(Ref ref, {required SignupFields input}) => ref.read(api).signUp(input);
```

- `steps` is a `const` map literal: step folder name to the fields it asks for, in order. Every field is in exactly one
  step. For an action called `approve`: `approveSteps`, `approveSkip`.
- The generated file declares `enum SignupStep { name, company, contact, review }` (a folder `contact_info` is
  `contactInfo`) and the section's handle gets `useFlow`, `flowOf` and `resume` in place of `useForm`
  (`use<Action>Flow`, `<action>FlowOf`, `<action>Resume` for another action).
- **Not supported:** a path with a dynamic segment above the flow, a localized path (`route.dart` `paths`), a flow
  inside a flow, a `form()` that takes a value. Each is an `fsp` error (`fespalier-troubleshooting`,
  `diagnostics-data-and-hooks.md`, "Multi-page forms").

## The layout and the steps

```dart
// signup/layout.dart
class SignupLayout extends HookConsumerWidget {
  const SignupLayout({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flow = SignupSection.useFlow(ref);          // draft on by default; draft: null keeps none
    return FormFlowScope(
      flow: flow,
      child: Column(children: [LinearProgressIndicator(value: flow.progress), Expanded(child: child)]),
    );
  }
}

// a step page
final flow = SignupSection.flowOf(context);
final f = flow.fields;
TextField(controller: f.email.controller, decoration: InputDecoration(errorText: f.email.error));
FilledButton(onPressed: flow.isPending ? null : () => flow.next(context), child: const Text('Next'));
```

- `flow.next(context)` checks **this step's fields only** (what each reads as, and `validate()`'s result filtered to
  them), marks the step done, keeps the draft and `go`es to the next step shown; on the last step it runs the action.
  `back(context)` goes to the previous step shown; `goTo(context, step)` opens a step when `canGoTo(step)` (shown, and
  every step shown before it done). `submit()` checks every field and takes the flow to the first step that owns a
  wrong one.
- **Server errors**: the action's `FieldErrors` go to the first step that owns an erroring field; what no step owns
  and the `message` are in `flow.error`.
- **Progress**: `step`, `steps` (the shown ones), `index`, `count`, `progress` (`(index + 1) / count`), `isFirst`,
  `isLast`, `isComplete(step)`, `canGoTo(step)`.

## Draft, deep links, leaving

- **The draft is on by default** and keeps the steps done with the fields (`{"v":1,"fields":{...},"steps":["name"]}`);
  written on `next`, `back`, `goTo`, in the background and when the layout is disposed; restored when it mounts.
- **Deep links**: a `guard.dart` in the section, `GuardResult guard(Ref ref, {required Uri uri}) =>
SignupSection.resume(ref, uri: uri);`, sends a link past what was done to the first step not done. It reads the
  flow on screen first (no draft needed), else the draft; an async storage makes it a `Future`.
- **Leaving**: `leave.dart` beside the `layout.dart`, no `page.dart` (the one page-less folder that may have one),
  `leaveIfClean(context, ref, page)` as for a page. It is the `onExit` of every step with `within:` the section's
  path: a navigation that stays inside passes without asking; leaving asks once. It takes no segment, query parameter
  or `extra`. The flow registers in each step's `LeaveScope`: `page.isDirty` is the flow's.
- **System back**: on a step that is not the first, Android's back calls `flow.back()` (a handler on the page's
  `LeaveScope`), and the iOS swipe is off; on the first step it leaves the flow, which asks.

## Test it

`package:fespalier_forms/testing.dart`: `expectStep(tester, SignupStep.contact)`, `seedFormDraft(container, id:, shape:,
fields:, steps: {SignupStep.name})`, `readFormDraftSteps(...)`, `LeavePrompts.answer(...)`. Boot at a step with
`pumpRouter(tester, AppRoutes.router(initialLocation: '/signup/name'))`, `enterText`, tap "Next", `expectStep`. A restart
is a second `pumpRouter` over the same `MemoryDataStorage`. `examples/features/test/flow_test.dart` is the sample.
