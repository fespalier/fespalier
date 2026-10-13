# Forms: fespalier_forms

`fespalier_forms` (since 0.11.0) is the form of an [`action.dart`](actions.md): typed fields with controllers the form owns, validation, the server's errors under their fields and a pending state. Before 0.11.0 it was part of `fespalier`; it moved out so an app with no forms ships none of it.

It is a companion package like `fespalier_flags`: no file kind of its own, no `fespalier:` key and no `fsp` command. You write a `form()` beside an action, `fsp gen` writes a `useForm` hook for it, and the hook returns the form.

What stays in `fespalier` because it does not need a form: [`FieldErrors`](actions.md#validate-and-fielderrors), the `validate()` that runs inside the action's provider (so `submit`, `useAction` and a test through the provider are refused the same way), and [`optimistic()`](actions.md#optimistic-updates-optimistic).

## Install

Add `fespalier_forms` under `dependencies:` next to `fespalier`, with the same git `url` and the same `ref`: pub resolves the two to one package only if they are the same repository dependency. The snippet, kept at the release's tag, is in [`packages/fespalier_forms/README.md`](../packages/fespalier_forms/README.md).

Then run `flutter pub get` and `fsp gen` (restart `fsp watch` or `fsp dev` if one is running, so it reads the new dependency). The generated file imports `package:fespalier_forms/fespalier_forms.dart` when some `action.dart` has a `form()`, and an app without a form does not import it. An app that has a `form()` and no `fespalier_forms` in `pubspec.yaml` gets an error at the `form()`:

```text
✗ (account)/nickname/action.dart:6  `form()` is the form of `action()`, and since 0.11.0 forms are in the fespalier_forms package: add `fespalier_forms` under `dependencies:` in pubspec.yaml, with the same git `url` and `ref` as fespalier
```

Pages use inferred types (`final form = NicknameRoute.useForm(ref, data: profile)`), so they need no import. Code that names `ActionForm`, `ActionField`, `ActionTextField`, `ActionFormFields`, `FieldCodec`, `ActionFormMessages`, `ActionFormValidation` or `useActionForm` imports `package:fespalier_forms/fespalier_forms.dart`: `package:fespalier` no longer exports them.

## `form()` and `useForm`

A form is the UI of one write, so it is not a file kind: `form()` is a _companion function_ in the `action.dart` of the action it belongs to, found by name. For the action called `action` it is `form`; for any other action, say `approve`, it is `approveForm` (and `useApproveForm`). A companion is never read as an action, even when it takes a `Ref` (that is an error).

```dart
// lib/app/(account)/nickname/action.dart
/// The input of the action, and so the fields of its form: a record with named fields.
typedef NicknameFields = ({String nickname, int? age, bool newsletter});

/// The form starts from the data the page passes (the profile it shows).
NicknameFields form(Profile profile) =>
    (nickname: profile.nickname, age: profile.age, newsletter: profile.newsletter);

/// Checked on the device before the action runs, and live in the form after a first submit.
FieldErrors? validate(NicknameFields input) => FieldErrors({
  if (input.nickname.trim().isEmpty) 'nickname': 'Enter a nickname',
  if (input.age case final age? when age < 13) 'age': 'You must be 13 or older',
});

/// The server has the last word: it can throw `FieldErrors({'nickname': 'That nickname is taken'})`.
Future<Profile> action(Ref ref, {required NicknameFields input}) => …;
```

```dart
// the page: a HookConsumerWidget, because useForm is a real hook
final form = NicknameRoute.useForm(ref, data: profile);
final f = form.fields;                         // a record of typed fields
TextField(
  controller: f.nickname.controller,
  decoration: InputDecoration(errorText: f.nickname.error),
),
CheckboxListTile(value: f.newsletter.value, onChanged: f.newsletter.didChange, …),
if (form.error case final e?) Text('$e'),      // what is not one field's
FilledButton(onPressed: form.onSubmit, child: …),  // null while the action runs: disabled
TextButton(onPressed: form.isDirty ? form.reset : null, child: …),
```

- **The input is a record with named fields**, written inline (`required ({int amount, String note}) input`) or as a `typedef` declared in the same `action.dart`; the generator reads the field names and types from there and nowhere else. `form()` returns exactly the input's type (as written) and takes no `Ref`: it takes the data the form starts from, or nothing.
- **`useForm`** is the generated member (`useApproveForm` for `approve`). **It is a real hook**: call it from a `HookConsumerWidget`'s `build` (`useAction` is not one).
  - It takes the action's keys, `data:` (only when `form()` takes a parameter; then required and of that type), and `validation:`, `resetOnSuccess:`, `messages:` and `draft:` ([Drafts](#drafts)). A key of the action can't be called `data`, `validation`, `resetOnSuccess`, `messages` or `draft`.
  - It returns an `ActionForm` with `fields`, `state`, `isPending`, `isDirty`, `isValid`, `error`, `onSubmit`, `submit()` and `reset()`.
- **Initial values and new data.** The form starts from `form(data)`.
  - When the page gets another data object (the action invalidated the data, or it was refreshed), the fields the user has not changed follow it, and the changed ones keep what was typed.
  - While the form's own action is running the data is not read again: during an optimistic write the page gets the patched value, and a rollback would otherwise wipe what was typed.
  - `reset()` goes back to the data the form was last given and clears the errors and the action's state. After a success the fields become the new baseline (`isDirty` is false); `resetOnSuccess: true` restarts them from `form(data)` instead.

## Fields

Fields are typed by the record's field types.

- `String`, `int`, `double`, `num` and their nullable forms are **text fields** with a `controller` that the form owns and disposes. An empty nullable one is `null`, an empty non-nullable number is `Required`, a bad number is `Enter a whole number` or `Enter a number`.
- Any other type (`bool`, an enum, a `DateTime`, a list) is a **value field**: bind it with `value` and `didChange(v)`, which ignores `null` for a non-nullable type so it fits `Checkbox.onChanged`.
- **Messages.** Pass `messages: ActionFormMessages(required: ..., integer: ..., number: ...)` to `useForm` to translate the three texts a field produces by itself.
- **Validation timing.** `validation: ActionFormValidation.afterSubmit` (the default) shows nothing before the first submit and every field as it changes after; `onChange` shows a field once the user has changed it.

## Submit and errors

- **Submit.** `onSubmit` (or `submit()`) reads the text fields, then asks `validate()`. If anything is wrong it stops there and **the action is not called**; otherwise it runs the action with the record the fields make. A sync action stays sync: `submit()` returns its value at once. `onSubmit` is `null` while the action runs, so `FilledButton(onPressed: form.onSubmit)` disables itself.
- **Errors per field.** A field shows, in this order: its own parse error, the `FieldErrors` the action threw for its name (until that field is edited), and what `validate()` says of it.
- **`form.error`** is what is not one field's: `FieldErrors.message`, the messages of keys that are no field, or the error of an action that failed otherwise.
- **`validate()`** is `FieldErrors? validate(Input input)`: see [`validate()` and `FieldErrors`](actions.md#validate-and-fielderrors). The form asks it too, so a check written once guards the form, `submit` and a test.
- **The server's answer.** A check the device can't make belongs in the action, which throws `FieldErrors({'nickname': 'That nickname is taken'})`. The [HTTP package](http.md#server-validation-errors-on-forms) maps a server's validation answer to it.
- **A write is never retried**, as for any [action](actions.md#actiondart-typed-writes): a failed submit shows its error, and trying again is the user's call.

## Drafts

A draft keeps what the user typed so that leaving the page, or closing the app, does not lose it: the form is found as it was when the route is opened again (since 0.11.0). It is **opt-in for each form**, never a default: a sign-in form must not write a password to disk.

```dart
final form = NicknameRoute.useForm(ref, data: profile, draft: const FormDraft());
// a form with a field that must not be kept:
final signIn = SignInRoute.useForm(ref, draft: const FormDraft(exclude: {'password'}));
```

`FormDraft(exclude:, maxAge:)` takes the names of the fields that are never written and how long a draft may be restored (7 days by default). The draft is read once, when the form starts: a `draft:` that changes later does nothing.

- **Where it is kept.** In `formDraftStorage`, a provider of `FutureOr<Storage<String, String>?>` that is, by default, the app's [`dataCacheStorage`](data.md#a-cache-that-survives-a-restart-datacache), so an app that caches its data on disk keeps drafts in the same place. Override it to keep them apart (`formDraftStorage.overrideWithValue(MemoryDataStorage())`). Null, the default of an app with no `dataCacheStorage`, keeps nothing.
- **Under which key.** `fespalier_forms.draft:<id>:<key>[:<scope>]`.
  - `<id>` is the action's file and name, written by the generator (`(account)/nickname/action.dart#action`).
  - `<key>` is the action's family key as a JSON list, each part spelled as a URL would (`[7]`; `[]` for an action with no keys). The same form on `/orders/7/edit` and `/orders/8/edit` has two drafts.
  - `<scope>` is `formDraftScope`, a provider of `String?` that is null by default. Give it the signed-in account's id, so that one account never sees the draft of another.
- **What is kept.** Only the fields the user changed, and only those a draft can keep.
  - A text field keeps its **raw text**: text that does not parse (an age of `abc`) survives, and is the field's error again on return.
  - A value field is kept when it is a `bool`, a `DateTime` or an enum fsp can find (see `DraftCodec`: `boolean`, `optionalBoolean`, `dateTime`, `optionalDateTime`, `enumOf(values)` and `optionalEnumOf(values)`, which the generated `useForm` picks by the field's type). A list, a record or any other type is not drafted.
  - What is in `exclude` is never written, and never restored from a draft that has it.
- **When it is written.** When the form is disposed (the page is gone) with changes, and when the app goes to the background (`AppLifecycleState.hidden`, `paused` or `detached`), because it may never come back. Never per keystroke, and no timer: the form owns an `AppLifecycleListener` and disposes it with the page. The same draft is not written twice. A form that is clean when disposed writes nothing, and deletes the draft it had restored.
- **When it is restored.** When the form starts. A storage whose `read` is synchronous (`MemoryDataStorage`, `PrefsDataStorage`) restores before the first build; one that answers later restores when it does, **only into the fields the user has not touched since**; a draft that arrives while the action runs is skipped, and not tried again (it stays on disk for the next visit). A restored field is dirty, so the rule that new data does not move a changed field keeps it, and `isDirty` is true. A draft that is expired, of another entry version, or that cannot be read is deleted.
- **When it is deleted.** After a **successful submit** (the fields are the new baseline), on `reset()`, and with `clearFormDrafts`. Leaving a form alone does not keep an empty draft.
- **Misspelled names.** In debug, a name in `exclude` that is no field of the form is an assertion, and a field called like `password`, `secret`, `pin` or `otp` that is not excluded prints a warning.
- **A form that changed.** The generator writes the form's `shape` (`nickname:String,age:int?,newsletter:bool`: the fields and their types) and the draft is saved for it: a draft written for another shape is dropped, not restored. Add, remove or retype a field, and the old drafts go.
- **Signing out.** `await clearFormDrafts(ref)` (from a widget) or `clearFormDraftsOf(ref)` (from a provider or an action) deletes every draft, whatever its scope, through an index it keeps in the storage (`fespalier_forms.drafts`). Call it when somebody signs out, besides giving `formDraftScope` the account. It also stops the forms still open from writing: a page that is disposed after the call keeps nothing. A form keeps the scope it started under.
- **Storage that evicts.** A storage with a size budget (`fespalier_storage`'s) may evict a draft, as it may evict anything it holds. The index is rewritten with every save, so it outlives the drafts it lists, but if it is evicted anyway `clearFormDrafts` misses the drafts that are left: for an app where sign-out must remove every draft, give `formDraftStorage` a storage with no budget. A draft is a convenience, not a record: nothing is lost that the server had.
- **A storage that throws** never costs the page: the error is printed in debug and the form goes on without a draft.

## Leaving with unsaved changes

A page with a form that has unsaved changes should ask before it goes (since 0.11.0). The question is asked by the page's [`leave.dart`](navigation.md#leaving-a-page-leavedart), and a form is a `LeaveSource` that registers itself with the page's scope: a `useForm` under a page whose folder has a `leave.dart` needs nothing else, and `page.isDirty` is "some form on the page has changed". `leaveIfClean` is the whole `leave()` for a page whose only question is that one:

```dart
// lib/app/(account)/nickname/leave.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_forms/fespalier_forms.dart';
import 'package:flutter/widgets.dart';

LeaveResult leave(BuildContext context, Ref ref, {required PageLeave page}) =>
    leaveIfClean(context, ref, page);
```

- **A clean page goes at once**, with a synchronous `true`: no `Future`, no microtask, no sheet. A form is clean when no field differs from what it started from (after a successful submit the fields are the new baseline).
- **Otherwise it asks** the app's `leavePrompt` (or the `ask:` of that call) and acts on the answer, a `LeaveChoice`:
  - `stay` answers `false`: the page and what was typed stay;
  - `discard` calls `page.discard()` and answers `true`: each form drops its draft and does **not** write one when the page is disposed;
  - `keep` waits for `page.keep()`, which writes each form's draft, and answers `true`: the form is found as it was when the route is opened again. A storage that writes later is waited for, so the page does not go before the draft is on the disk.
- **`keep` needs a changed field the draft keeps.** A form can keep (`canKeep`) when its `useForm` was given a `draft:`, there is a `formDraftStorage`, and a changed field is one the draft holds: not in `exclude`, and a text field or a value field with a `DraftCodec`. Otherwise the sheet has two buttons (a form changed only in its `password` has nothing a draft could keep, and keeping would delete the draft it had). A form with no `draft:` still asks: its choice is between staying and losing the changes.
- **The back gestures.** The page is wrapped in a `PopScope`, so the iOS edge swipe is on while every form is clean and off while one has changed (the sheet is the only way out of a changed form); Android's back asks like a link does. See [the back gestures](navigation.md#leaving-a-page-leavedart).
- **Navigate after the save, not from inside it.** Go to the next page after `await form.submit()` (or when the action's state turns to data), never from the action body: the page would be asked while the form still has its changes, and the question would come after a successful save.
- **A discard that the page's route overruled.** If a parent route's `leave()` refuses after the form was discarded, the page stays with the text as typed, but the form writes no draft (on dispose or in the background) until the next edit.
- **A page with a `leave.dart` and no form** has no source, so `page.isDirty` is false and nothing asks, but its iOS swipe is off. Register a source for it, or leave the `leave.dart` out.

**The sheet.** The default prompt, `askToLeaveSheet()`, is a bottom sheet on Flutter's `showModalBottomSheet`, opened on the root navigator, with "Keep editing", "Discard" and, when `page.canKeep`, "Keep as draft". Dismissing it (the scrim, a swipe down) is "Keep editing". Translate it with `LeaveSheetMessages`, for the whole app or for one call:

```dart
// the whole app
ProviderScope(
  overrides: [
    leavePrompt.overrideWithValue(
      askToLeaveSheet(
        messages: const LeaveSheetMessages(
          title: 'Jeter les modifications ?',
          body: 'Ce que vous avez change n\'est pas enregistre.',
          stay: 'Continuer',
          discard: 'Jeter',
          keep: 'Garder un brouillon',
        ),
      ),
    ),
  ],
  child: const App(),
)

// one page
LeaveResult leave(BuildContext context, Ref ref, {required PageLeave page}) =>
    leaveIfClean(context, ref, page, ask: askToLeaveSheet(messages: nicknameMessages));
```

**Your own prompt.** `leavePrompt` is a `Provider<LeavePrompt>`, where a `LeavePrompt` is `FutureOr<LeaveChoice> Function(BuildContext context, PageLeave page)`: override it with a sheet of your design system, and answer a `LeaveChoice` (now or later). The `context` is the root navigator's, so a sheet opens above every layout and tab bar.

**An app on material_ui.** The default sheet is Flutter's and needs Flutter's `MaterialLocalizations`, which a material_ui `MaterialApp` does not provide. Override the prompt with that library's own sheet:

```dart
leavePrompt.overrideWithValue((context, page) async {
  final choice = await showMySheet<LeaveChoice>( // material_ui's own, or your design system's
    context: context,
    builder: (sheet) => MyLeaveSheet(
      canKeep: page.canKeep,
      onChoice: (c) => Navigator.of(sheet).pop(c),
    ),
  );
  return choice ?? LeaveChoice.stay;
}),
```

**What it does not cover.** Everything [`leave.dart` does not ask about](navigation.md#leaving-a-page-leavedart): a tab switch (the page is parked, not gone), a parked tab's pages when the whole layout leaves, a process kill. A form still writes its draft when it is disposed and when the app goes to the background, so drafts cover what the question does not.

## Multi-page forms

A form that is too long for one screen is a **flow** (since 0.11.0): the steps are pages, they share **one form and one draft**, and the question about unsaved changes is asked **once**, when the user leaves the flow. A flow is the section fespalier already has, a folder with a `layout.dart` and no `page.dart`, with an `action.dart` whose `form()` gains one companion, `const steps`. Each step is a child folder with a `page.dart`, so every step is a typed route with a URL: deep links, guards, transitions, `fsp routes` and the generated tests work as for any other page. The layout outlives the changes of step (a `ShellRoute` keeps its page), so it owns the form.

```text
lib/app/signup/
  layout.dart       SignupLayout({required Widget child})   // holds the flow, shows the progress
  action.dart       form(), steps, skip(), validate(), action()
  guard.dart        resume at the first step not done
  leave.dart        asked once, when leaving the flow
  name/page.dart      SignupNamePage()      -> /signup/name
  company/page.dart   SignupCompanyPage()   -> /signup/company   (skipped for individuals)
  contact/page.dart   SignupContactPage()   -> /signup/contact
  review/page.dart    SignupReviewPage()    -> /signup/review
```

### Declaring the steps

```dart
// signup/action.dart
typedef SignupFields = ({String name, bool business, String? company, String email, String? phone});

SignupFields form() => (name: '', business: false, company: null, email: '', phone: null);

/// Which step asks for which fields, in order; a step with none (the review) is just a page.
const steps = {
  'name': ['name', 'business'],
  'company': ['company'],
  'contact': ['email', 'phone'],
  'review': <String>[],
};

/// Optional: a step that is left out for this input.
bool skip(SignupStep step, SignupFields input) => step == SignupStep.company && !input.business;

FieldErrors? validate(SignupFields input) => FieldErrors({if (input.name.isEmpty) 'name': 'Enter your name'});

Future<Account> action(Ref ref, {required SignupFields input}) => ref.read(api).signUp(input);
```

- **`steps`** is a `const` map literal from a step folder's name to the fields of the input it asks for. The order is the order of the flow. Every field belongs to exactly one step, and every step is a **direct** child folder with a `page.dart` (nested flows are not supported). For an action called `approve` the names are `approveSteps` and `approveSkip`.
- **The generated file** declares `enum SignupStep { name, company, contact, review }` (a folder `contact_info` is `contactInfo`) and gives the section's handle `useFlow` (for the layout), `flowOf` (for a step page) and `resume` (for a guard), in place of `useForm`. For another action they are `use<Action>Flow`, `<action>FlowOf` and `<action>Resume`.
- **`skip(step, input)`** is optional and decides from the input as it is now, so it follows the user's own answers: it is read for the progress, for `next` and `back`, and by `resume`.
- **A flow sits at a path with no dynamic segment** for now: its steps are `go`ne to by typed routes the section holds. Its `form()` takes no value (`resume` runs in a guard, before any data is loaded).
- A key called `draft`, `messages` or `validation` is reserved, as for `useForm`. A `const` map literal called `steps` (or `<action>Steps`) beside a `form()` is a flow; a `steps` of any other shape (a number, a list) is yours and is left alone.

The layout makes the flow and shares it with the pages below:

```dart
class SignupLayout extends HookConsumerWidget {
  const SignupLayout({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flow = SignupSection.useFlow(ref);
    return FormFlowScope(
      flow: flow,
      child: Column(children: [
        LinearProgressIndicator(value: flow.progress),
        Expanded(child: child),
      ]),
    );
  }
}

// a step page
final flow = SignupSection.flowOf(context);
final f = flow.fields; // the fields of every step, typed as in `useForm`
TextField(controller: f.email.controller, decoration: InputDecoration(errorText: f.email.error));
FilledButton(onPressed: flow.isPending ? null : () => flow.next(context), child: const Text('Next'));
```

`useFlow` takes the action's keys, `validation:`, `messages:` and `draft:` (see below), and returns a `FormFlow`, which is an `ActionForm`: `fields`, `isDirty`, `isPending`, `error`, `reset()`, `submit()` and the rest of [`form()` and `useForm`](#form-and-useform) work as they do for one page. `flowOf` rebuilds the page when the flow changes.

### Moving between steps

- **`next(context)`** checks the **current step's fields only**: what each reads as (an age of `abc`) and what `validate()` says of **those** fields; the errors of the other steps are not shown yet. When they are fine it marks the step done, keeps the draft and `go`es to the next step shown. It returns `false` (with the errors under the fields) when a field is wrong. On the last step shown it runs the action, as `submit()` does.
- **`back(context)`** goes to the previous step shown (false on the first). Nothing is lost: the form lives in the layout.
- **`goTo(context, step)`** opens a step to edit it (from a review), when `canGoTo(step)` allows it: the step is shown and every step shown before it is done.
- **Enter a flow with `go`** (`SignupRoute`'s first step `.go(context)`, or a link). `next`, `back` and `goTo` use `go` too, so a flow that was `push`ed loses the page under it on the first step change; the flow is a place, not a modal stack.
- Steps are real navigation (`go`), so each is a history entry on the web: the browser's back reaches the previous step's URL. The Android back, on a step that is not the first, goes to the previous step instead of leaving the flow (see Leaving the flow).

### Validation and the server's errors

- Each field shows its errors once its step was tried with `next`, or after `submit()`; `validation: ActionFormValidation.onChange` still shows a changed field at once.
- **`submit()`** checks every field. A field that is wrong takes the flow to the **first step that asks for it**, with the error shown. Then it runs the action with all the fields.
- **The server's `FieldErrors`** are mapped by the steps: the flow goes to the first step that owns an erroring field, and the message is under the field. What belongs to no field (the `message`, a key that is none of the form's) is in `flow.error`, on the page you call `submit()` from, usually the review.
- On success the draft is deleted, the steps done are forgotten and the fields are the new baseline.

### Drafts and deep links

- **The draft is on by default** in a flow (`useFlow(ref, draft: const FormDraft())`; pass `draft: null` to keep none, or `FormDraft(exclude: {'password'})`): surviving back, forward and a restart is the point of a flow. It is the [route-level draft](#drafts) of the action, and it keeps the **steps done** with the fields (`{"v":1,"fields":{...},"steps":["name"]}`).
- **When it is written:** on `next`, `back` and `goTo` (a step change is an event, not a timer), when the app goes to the background and when the layout is disposed. **When it is restored:** when the layout mounts, so a deep link or a restart finds the form as it was.
- **`resume`** is what a guard in the section returns, so that a link into the middle opens where the user had got to:

```dart
// signup/guard.dart
GuardResult guard(Ref ref, {required Uri uri}) => SignupSection.resume(ref, uri: uri);
```

`resume` returns the location of the first step shown that is not done when `uri` is a step past it, else `null`. What is done comes from the flow on screen when there is one (so it works with no draft), else from the draft; with neither, only the first step opens. The flow on screen is found by its draft key (action, family key and `formDraftScope`) in a registry shared by the whole process, not per `ProviderContainer`: two containers of one app (a test that boots twice) see the last layout mounted. A storage that answers later makes the guard a `Future`. A link to a step that is skipped goes to the first step not done. A link that is no step's is left alone.

### Leaving the flow

The flow's `leave.dart` goes beside the `layout.dart`, with no `page.dart`: this is the one page-less folder that may have one. `leaveIfClean` works unchanged, with "Keep as draft":

```dart
// signup/leave.dart
LeaveResult leave(BuildContext context, Ref ref, {required PageLeave page}) =>
    leaveIfClean(context, ref, page);
```

- The generator applies it to **every step's `GoRoute`** with `within:` the section's path, so a navigation that stays inside the section (a step to the next, `back`, `goTo`, the browser's back) is **not asked**, and leaving it is, once. A pop is judged by where it lands (the location without the exiting step).
- `page.isDirty` is the flow's: the flow registers in each step page's `LeaveScope`.
- **The system back:** on a step that is not the first, Android's back calls `flow.back()` instead of popping (a back handler on the page's `LeaveScope`); on the first step it leaves the flow, which asks. While a step has a handler the iOS edge swipe is off.
- What [`leave.dart` does not ask about](navigation.md#leaving-a-page-leavedart) holds for a flow too, and the flow's `leave()` takes no segment, query parameter or `extra`.

### Progress

`flow.step` (from the current location), `flow.steps` (the steps shown, in order), `flow.index` (0-based, among the steps shown), `flow.count`, `flow.progress` (`(index + 1) / count`, so it starts at `1 / count`, not 0; for a `LinearProgressIndicator(value:)`), `flow.isFirst`, `flow.isLast`, `flow.isComplete(step)` and `flow.canGoTo(step)`. `skip()` changes `steps` and `count` as the user answers.

### Testing a flow

`package:fespalier_forms/testing.dart` adds, for a flow:

- `expectStep(tester, SignupStep.contact)` expects the router to be at that step (the last segment of the location is the step's name; give `route: const SignupContactRoute()` to compare the whole location);
- `seedFormDraft(container, id:, shape:, fields:, steps: {SignupStep.name})` writes the draft of "the app was closed after the first step", and `readFormDraftSteps(container, id:, shape:)` reads the steps a draft has done;
- `LeavePrompts.answer(LeaveChoice.keep)` answers the question at once.

A test boots at a step, types, taps "Next" and `expectStep`s; a restart is a second `pumpRouter` over the same `MemoryDataStorage`; a deep link is `initialLocation: '/signup/review'` with a seeded draft. `examples/features` has `lib/app/signup/` and `test/flow_test.dart`: next checking only its own fields, a skipped step, `goTo` from the review, a server error that goes to the step that owns it, the draft surviving a restart, a deep link resumed, the leave asked once and the Android back.

## Testing

A form is tested through its page: `pumpRouter` boots the app at the location (see [Testing](testing.md)), `enterText` and `tap` drive it, and the pending write is held on a `Completer`, so no timer and no `runAsync` is needed.

```dart
testWidgets('a taken nickname is shown under its field', (tester) async {
  server.taken = 'bob';
  await pumpRouter(
    tester,
    AppRoutes.router(initialLocation: '/nickname'),
    overrides: [profileServerProvider.overrideWithValue(server)],
  );
  await tester.enterText(find.widgetWithText(TextField, 'Nickname'), 'bob');
  await tester.tap(find.text('Save'));
  await tester.pump();
  expect(find.text('That nickname is taken'), findsOneWidget);
});
```

- **Hold the save** on a `Completer` in your fake server to look at the pending state (`onSubmit` is `null`), then complete it and `pump`.
- **`package:fespalier_forms/testing.dart`** has `isFieldErrors(fields, message:)`, a matcher for the `FieldErrors` an action throws: `expectLater(run(input), throwsA(isFieldErrors({'nickname': 'Taken'})))`.
- **The leave question** (since 0.11.0). `LeavePrompts.answer(LeaveChoice.discard)` in `overrides` answers the prompt at once, with no sheet: `pumpRouter(tester, router, overrides: [LeavePrompts.answer(LeaveChoice.keep)])`. To test the sheet itself, change a field, navigate away and tap "Keep editing", "Discard" or "Keep as draft"; `readFormDraft` then says whether a draft was kept. `examples/features` has `test/leave_nickname_test.dart` (stay, discard, keep, the iOS swipe on when clean).
- **Drafts.** Share one `MemoryDataStorage` between two `pumpRouter` calls (or leave a page and come back) to see a draft kept and restored. `seedFormDraft(container, id:, key:, shape:, fields:)` writes the draft of "the app was closed with this typed in", and `readFormDraft(container, id:, key:, shape:)` reads what a form kept; both go through the container's `formDraftStorage` and `formDraftScope`. The `id` and `shape` are the strings in `app.g.dart`'s `useForm`. The app going to the background is `tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused)` (and back to `resumed` before the next `pump`).
- **`examples/features`** has `test/forms_test.dart`: validation, errors per field, a pending submit, reset, an optimistic patch that the server's value replaces, and the nickname form's draft.
- A form disposes its controllers with the page; a test under `LeakTesting` finds nothing left behind.
- The package starts no timer, schedules no microtask and reads no clock (`test/no_timers_test.dart` checks `lib/`).
