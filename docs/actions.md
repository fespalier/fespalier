# Actions and forms

## `action.dart`: typed writes

`data.dart` is the read side of a route. `action.dart` is the write side: a submit, a save, a
delete, a "mark as paid". It sits beside a `page.dart`, and it takes the same segments and query
parameters, plus the value being written, `input`:

```dart
// lib/app/orders/$id/refund/action.dart
Future<Refund> action(Ref ref, {required int id, required RefundInput input}) =>
    ref.read(apiProvider).refund(id, input);
```

fespalier turns it into a provider with pending and error state, and into helpers on the typed
route. After a success it invalidates the data the write made stale, so the page shows what the
server says now: no `isSubmitting` field, no `try`/`catch`, and no `ref.invalidate` to forget.

```dart
// in a HookConsumerWidget (or any ConsumerWidget): the state of the write, and a way to run it
final refund = RefundRoute.useAction(ref, id: id);
FilledButton(
  onPressed: refund.isPending ? null : () => refund.call(RefundInput(amount: 10)),
  child: Text(refund.isPending ? 'Refunding...' : 'Refund'),
),
if (refund.hasError) Text('${refund.state.error}'),            // the page stays; error.dart is not used
if (refund.state.value case final done?) Text('Refunded ${done.amount}'),

// in a callback or a test: run it once, get the result, or the exception it threw
final Refund done = await RefundRoute.submit(ref, id: 1, input: input);
```

- **Parameters.** Segments and query parameters bind exactly as in
  [`data.dart`](data.md#datadart-a-function-a-selector-or-a-provider): the same names, the same types
  and the same errors. The one other parameter is `input`: **named, `required`**, of any type
  (`RefundInput`, `String`, a record, a `List`, `Object?`). Its type is read from the source like
  a typed [`extra`](navigation.md#typed-extra)'s, imports and a type declared in the file included, so the
  generated `submit` is typed. A `Ref ref` comes first, positional.
- **Return type.** `Future<T>`, `FutureOr<T>` or a plain `T` (`Future<void>` is fine). It is
  spelled out. **The helpers keep what the function is**: a sync action's `submit` returns its
  value at once, with no `Future` and no extra frame, a `FutureOr<T>` one's returns what the
  function returned, and a `Future<T>` one's returns a `Future<T>`. A `Stream` is an error: a
  write has one result.
- **Several actions per file.** Every public top-level function that takes a `Ref` first is an
  action, and its name is the name of its helpers. A function called `action` gets the plain ones:

  | Function  | Provider (`XRoute.…`) | Runs it once                  | Hook for `build`         |
  | --------- | --------------------- | ----------------------------- | ------------------------ |
  | `action`  | `action(keys)`        | `submit(ref, keys…, input:)`  | `useAction(ref, keys…)`  |
  | `approve` | `approveAction(keys)` | `approve(ref, keys…, input:)` | `useApprove(ref, keys…)` |

  A helper can't be named like a member of the route (`go`, `refresh`, `watch`, `data`, …), a
  segment or query parameter of it, or another action's helper (a function called `submit` next to
  `action`): the generator says which.

- **The provider** is a generated `Notifier` family, `XRoute.action(id)` (`XRoute.action` when
  there are no keys), whose state is `AsyncValue<T?>`: `AsyncData(null)` while idle, then
  `AsyncLoading`, then `AsyncError` or `AsyncData` of the result. It works without a widget:
  `container.read(RefundRoute.action(1).notifier).call(input)`, which is what a test can do. Each
  key has a state of its own, and an `autoDispose` provider is dropped when nothing watches it,
  except while a write is in flight.
- **`useAction`** takes the keys and returns a handle: `state` (the same `AsyncValue<T?>`),
  `isPending`, `hasError`, `fieldErrors` (the [`FieldErrors`](#forms-form-and-validate) the last
  run failed with, since 0.8.1, or null), `reset()`, and `call(input)`. `call` runs the action and completes with
  the result, or with `null` when it failed, because the error is in `state`: an `onPressed:
() => refund.call(input)` can't leave an unhandled error behind. `submit` is the other way: it
  throws what the action threw, for code that wants to handle it (and the error is in `state` too).
  Neither navigates, and neither is for `build`'s own body: call them from an event handler.
  (`useAction` is a hook by name only: it needs a `WidgetRef`, not hooks, and works in any
  `ConsumerWidget`.)
- **`submit`, `useAction` and the provider are static**, like [`watch` and `read`](data.md#typed-helpers-on-the-route):
  `RefundRoute(id: 1).submit(...)` would have to name `Refund`, which the generated file can't (see
  [Design notes](faq.md#design-notes)). The types are inferred from the provider, never `dynamic`. The
  input is the one type that is spelled out, and it is read from your file.

**After a success.** The data the write made stale is invalidated, and loads again (with
[`keep_previous`](data.md#retries-and-reloads), what the page shows stays until the new value is there):

- by default the route's own `data.dart` and the [section data](data.md#section-data) above it: the set
  [`AppRoutes.dataAt`](data.md#from-a-location-to-its-data) lists for the route, for the keys the action
  was called with;
- or what `const invalidates = [...]` lists, which **replaces** that set. Name typed routes and
  section handles (`RefundRoute`, `OrderRoute`, `TeamsTeamIdSection`): providers aren't `const`,
  and the generator knows which provider each one is. `const invalidates = <Object>[];`
  invalidates nothing. Anything else the write touches, a provider of your own, can be
  invalidated by the action itself, which has a `ref`.

```dart
// lib/app/orders/$id/refund/action.dart
import 'package:my_app/app.g.dart';

/// The quote on this page, and the order page above it, are stale after a refund.
const invalidates = [RefundRoute, OrderRoute];

Future<Refund> action(Ref ref, {required int id, required RefundInput input}) => …;
```

A listed route's `data.dart` is keyed by something, and the action has to take it, with that type,
to say which one to invalidate (`OrderRoute`'s `data.dart` takes `int id`, so the action takes
`id`; a `String? q` of a search page's data is one the action takes too). When it can't tell,
that's an error that says so.

**Errors.** A failed write is `AsyncError` in the state, and it is **not** the page's: the nearest
[`error.dart`](data.md#datadart-a-function-a-selector-or-a-provider) is not used, because a failed refund
shouldn't replace the form that started it. **A write is never retried**: the generated provider
doesn't use Riverpod's [retry](data.md#retries-and-reloads), whatever `ProviderScope(retry:)` says, and
nothing else runs it again. A failed write invalidates nothing. Trying again is the user's call:
the next `call` or `submit` replaces the error, and `reset()` clears it.

**Concurrent runs, and a page that goes away.** Nothing stops a second `call` while one is pending:
both run, each invalidates after its own success, and the state follows the last one started (a
late result of the first doesn't replace it). Disable the button while `isPending` when a double
write is wrong. The provider is kept alive until the write completes, even if its page is popped
meanwhile, so the write still finishes and still refreshes the data; the state is only written
while the provider is alive, so a submission that finishes after the page, or the whole container,
is gone doesn't throw. After an `await` in a callback, check `context.mounted` before navigating.

**Navigation is the caller's.** An action returns what it wrote, and doesn't navigate:

```dart
final done = await RefundRoute.submit(ref, id: id, input: input);
if (context.mounted) ReceiptRoute(id: id).go(context);
```

**In a section's folder.** An `action.dart` in a folder with a `layout.dart` and no `page.dart`
writes to the section. Its helpers are on the section's handle (`TeamsTeamIdSection.addMember(ref,
teamId: 'acme', input: 'carol')`), and what it invalidates by default is the section's own data and
the sections above it. A section with no `data.dart` gets a handle for its actions alone
(`ShopSection`), named like [any section's](data.md#section-data).

Since 0.5.0. Forms and optimistic updates (since 0.8.1) are in the two subsections after the list
below; without them, `state` plus `invalidates` cover most pages.

`fsp new 'orders/[id]/refund' --action` scaffolds one, with the path's segments and an `Object?`
input to replace with your own type. `fsp routes` tags the route `action` (also in the `tags` of
`--json`, which only gains the value). The generator reports, with a code frame:

- an `action.dart` with no `page.dart`, and no `layout.dart` of a page-less folder, beside it, or
  with no function in it that takes a `Ref` first;
- a missing `input`, or one that is positional, not `required` or untyped;
- a parameter that is neither a segment, a query parameter nor `input`, a missing return type, a
  `Stream`, a `Future` with no type argument;
- an `invalidates` that is not a `const` list literal of names, a name that is neither a typed
  route nor a section handle or has no `data.dart`, and a key of the data it invalidates that the
  action doesn't take;
- helper names that collide;
- since 0.8.1, a `form()`, `validate()` or `optimistic()` that doesn't fit its action (see below).

### Forms: `form()` and `validate()`

Since 0.8.1. A form is the UI of one write, so it is not a file kind: `form()`, `validate()` and
`optimistic()` are _companion functions_ in the `action.dart` of the action they belong to, found
by name. For the action called `action` the companion is the role itself; for any other action,
say `approve`, it is `approveForm`, `approveValidate` and `approveOptimistic`. A companion is never
read as an action, even when it takes a `Ref` (that is an error). An app that writes none of them
generates exactly what 0.7.0 did.

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

- **The input is a record with named fields**, written inline (`required ({int amount, String
note}) input`) or as a `typedef` declared in the same `action.dart`; the generator reads the
  field names and types from there and from nothing else. `form()` returns exactly the input's
  type (as written) and takes no `Ref`: it takes the data the form starts from, or nothing.
- **`useForm`** is the generated member (`useApproveForm` for `approve`). It takes the action's
  keys, `data:` (only when `form()` takes a parameter, then required and of that type), and
  `validation:`, `resetOnSuccess:` and `messages:`. It returns an `ActionForm` with `fields`,
  `state`, `isPending`, `isDirty`, `isValid`, `error`, `onSubmit`, `submit()` and `reset()`.
  **It is a real hook**: call it from a `HookConsumerWidget`'s `build`. (`useAction` is not.) A
  key of the action can't be called `data`, `validation`, `resetOnSuccess` or `messages`.
- **Fields** are typed by the record's field types. `String`, `int`, `double`, `num` and their
  nullable forms are text fields with a `controller` that the form owns and disposes; an empty
  nullable one is `null`, an empty non-nullable number is `Required`, a bad number is `Enter a
whole number` or `Enter a number` (pass `messages: ActionFormMessages(...)` to translate them).
  Any other type (`bool`, an enum, a `DateTime`, a list) is a value field: bind it with `value` and
  `didChange(v)`, which ignores `null` for a non-nullable type so it fits `Checkbox.onChanged`.
- **Submit.** `onSubmit` (or `submit()`) first reads the text fields, then asks `validate()`; if
  anything is wrong it stops there and **the action is not called**. Otherwise it runs the action
  with the record the fields make. A sync action stays sync: `submit()` returns its value at once.
  `onSubmit` is `null` while the action runs, so `FilledButton(onPressed: form.onSubmit)`
  disables itself.
- **Errors per field.** A field shows, in this order, its own parse error, the `FieldErrors` the
  action threw for its name (until that field is edited), and what `validate()` says of it.
  `validation: ActionFormValidation.afterSubmit` (the default) shows nothing before the first
  submit and every field as it changes after; `onChange` shows a field once the user has changed
  it. `form.error` is what is not one field's: `FieldErrors.message`, the messages of keys that are
  no field, or the error of an action that failed otherwise.
- **`validate()`** is `FieldErrors? validate(Input input)`: it takes no `Ref`, so it is a check
  the device can make. It does not need a record input. It also runs **inside the action's
  provider, before the action**, so `submit`, `useAction`'s `call` and a test through the provider
  are refused the same way: the write never starts, there is no loading state, and the error
  (`FieldErrors`) is in `state` and `fieldErrors`. A check that needs the server belongs in the
  action, which throws `FieldErrors({'nickname': 'That nickname is taken'})`.
- **Initial values and new data.** The form starts from `form(data)`. When the page gets another
  data object (the action invalidated the data, or it was refreshed), the fields the user has not
  changed follow it and the changed ones keep what was typed. While the form's own action is
  running the data is not read again: during an optimistic write the page gets the patched value,
  and a rollback would otherwise wipe what was typed. `reset()` goes back to the data the form was
  last given and clears the errors and the action's state. After a success the fields become the
  new baseline (`isDirty` is false); `resetOnSuccess: true` restarts them from `form(data)`
  instead.

### Optimistic updates: `optimistic()`

Since 0.8.1. `T optimistic(T current, Input input)` is what the page shows of one `data.dart` from
the moment a write starts, until the server's answer is in:

```dart
// lib/app/teams/$teamId/action.dart
Team addMemberOptimistic(Team team, String input) =>
    Team(team.name, [...team.members, input]);

Future<void> addMember(Ref ref, {required String teamId, required String input}) async => …;
```

- **The target** is the `data.dart` the action invalidates whose type is `T`. When several match,
  the folder's own data comes first, then the sections above it (innermost first), then the rest
  of `invalidates` in the order listed. The action has to invalidate it (the default set does; an
  explicit `invalidates` must list it). If it doesn't, that is an error: a patch over data that
  never loads again would have no end. Only the target is patched; other invalidated data just
  reloads.
- **The sequence.** The patch is shown from the start of the write. On a failure it is removed
  (the rollback). On a success it **stays over the old value until the invalidated data has loaded
  again**, then the server's value replaces it: no frame shows the old value in between. This
  holds with `keep_previous: false` too: while a write that patched the data settles, `DataView`
  does not show `loading.dart`, because the page has already shown the result. A reload that is not
  settling a write still shows it as configured.
- **Concurrent writes** apply oldest first; a failure removes only its own patch.
- **Which reads are patched.** `DataView`, `SectionView` (the layout and every page that takes the
  section's data by type) and the typed `XRoute.watch` / `XSection.watch` show the patched value.
  `XRoute.data` (the provider), `read`, `refresh`, `prefetch`, `preload` and `AppRoutes.dataAt`
  are the server's value. A dependency-triggered reload (`AsyncLoading` with a value) is returned
  unpatched by `watch`, and still patched in `DataView`.
- **The patch holds until the data loads again, even to an equal value**, because it is the
  reload that ends it, not a comparison. A patch that throws is reported through
  `FlutterError.reportError` (context `while applying an optimistic() patch`) and skipped; it
  never turns into `error.dart`.
- If the page leaves in the middle of a write, the write still finishes and still invalidates.
