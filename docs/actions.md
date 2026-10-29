# Actions

## `action.dart`: typed writes

`data.dart` is the read side of a route; `action.dart` is the write side: a submit, a save, a delete, a "mark as paid". It sits beside a `page.dart`, takes the same segments and query parameters, plus the value being written, `input`:

```dart
// lib/app/orders/$id/refund/action.dart
Future<Refund> action(Ref ref, {required int id, required RefundInput input}) =>
    ref.read(apiProvider).refund(id, input);
```

fespalier turns it into a provider with pending and error state, and into helpers on the typed route. After a success it invalidates the data the write made stale, so the page shows what the server says now: no `isSubmitting` field, no `try`/`catch`, no `ref.invalidate` to forget.

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

Since 0.5.0. `state` plus `invalidates` covers most pages; `validate()` and optimistic updates (since 0.8.1) are in the two subsections below, and forms (the `fespalier_forms` package, since 0.11.0) are on [their own page](forms.md).

- **Parameters.** Segments and query parameters bind exactly as in [`data.dart`](data.md#datadart-a-function-a-selector-or-a-provider): same names, types and errors. The one other parameter is `input`: **named, `required`**, of any type (`RefundInput`, `String`, a record, a `List`, `Object?`). Its type is read from the source like a typed [`extra`](navigation.md#typed-extra)'s, so the generated `submit` is typed. A `Ref ref` comes first, positional.
- **Return type.** `Future<T>`, `FutureOr<T>` or a plain `T` (`Future<void>` is fine), spelled out. **The helpers keep what the function is**: a sync action's `submit` returns its value at once (no `Future`, no extra frame), a `FutureOr<T>` one's returns what the function returned, and a `Future<T>` one's returns a `Future<T>`. Since 0.25.0 a `Stream<T>` is a [streaming action](#streaming-actions-streamt), whose state follows the items as they come (until 0.24.0 it was an error).
- **Several actions per file.** Every public top-level function that takes a `Ref` first is an action, and its name is the name of its helpers. A function called `action` gets the plain ones:

  | Function  | Provider (`XRoute.…`) | Runs it once                  | Hook for `build`         |
  | --------- | --------------------- | ----------------------------- | ------------------------ |
  | `action`  | `action(keys)`        | `submit(ref, keys…, input:)`  | `useAction(ref, keys…)`  |
  | `approve` | `approveAction(keys)` | `approve(ref, keys…, input:)` | `useApprove(ref, keys…)` |

  A helper can't be named like a member of the route (`go`, `refresh`, `watch`, `data`, …), a segment or query parameter of it, or another action's helper (a function called `submit` next to `action`): the generator says which.

- **The provider** is a generated `Notifier` family, `XRoute.action(id)` (`XRoute.action` with no keys). Its state is `AsyncValue<T?>`: `AsyncData(null)` while idle, then `AsyncLoading`, then `AsyncError` or `AsyncData` of the result (a streaming action has [a state of its own](#streaming-actions-streamt)). It works without a widget (`container.read(RefundRoute.action(1).notifier).call(input)`, which is what a test can do). Each key has its own state; an `autoDispose` provider is dropped when nothing watches it, except while a write is in flight.
- **`useAction`** takes the keys and returns a handle: `state` (the same `AsyncValue<T?>`), `isPending`, `hasError`, `fieldErrors` (the [`FieldErrors`](#validate-and-fielderrors) the last run failed with, since 0.8.1, or null), `reset()` and `call(input)`.
  - `call` runs the action and completes with the result, or with `null` when it failed (the error is in `state`), so `onPressed: () => refund.call(input)` can't leave an unhandled error behind.
  - `submit` is the other way: it throws what the action threw, for code that wants to handle it (the error is in `state` too).
  - Neither navigates, and neither is for `build`'s own body: call them from an event handler. `useAction` is a hook by name only: it needs a `WidgetRef`, not hooks, and works in any `ConsumerWidget`.
- **`submit`, `useAction` and the provider are static**, like [`watch` and `read`](data.md#typed-helpers-on-the-route) ([why](faq.md#why-an-actions-submit-is-static-and-its-input-is-typed)). Types are inferred from the provider, never `dynamic`; the input is the one type spelled out, and it is read from your file.

**After a success.** The data the write made stale is invalidated and loads again (with [`keep_previous`](data.md#retries-and-reloads), what the page shows stays until the new value is there):

- **By default**: the route's own `data.dart` and the [section data](data.md#section-data) above it, the set [`AppRoutes.dataAt`](data.md#from-a-location-to-its-data) lists for the route, for the keys the action was called with.
- **Or what `const invalidates = [...]` lists**, which **replaces** that set. Name typed routes and section handles (`RefundRoute`, `OrderRoute`, `TeamsTeamIdSection`): providers aren't `const`, and the generator knows which provider each one is. `const invalidates = <Object>[];` invalidates nothing. Anything else the write touches (a provider of your own) the action can invalidate itself, since it has a `ref`.

```dart
// lib/app/orders/$id/refund/action.dart
import 'package:my_app/app.g.dart';

/// The quote on this page, and the order page above it, are stale after a refund.
const invalidates = [RefundRoute, OrderRoute];

Future<Refund> action(Ref ref, {required int id, required RefundInput input}) => …;
```

A listed route's `data.dart` is keyed by something, and the action has to take that key, with that type, to say which one to invalidate (`OrderRoute`'s `data.dart` takes `int id`, so the action takes `id`; a `String? q` of a search page's data is one the action takes too). When it can't tell, that is an error that says so.

- **Errors.** A failed write is `AsyncError` in the state, and it is **not** the page's: the nearest [`error.dart`](data.md#datadart-a-function-a-selector-or-a-provider) is not used, because a failed refund shouldn't replace the form that started it.
- **A write is never retried.** The generated provider doesn't use Riverpod's [retry](data.md#retries-and-reloads), whatever `ProviderScope(retry:)` says, and nothing else runs it again. A failed write invalidates nothing. Trying again is the user's call: the next `call` or `submit` replaces the error, and `reset()` clears it.
- **Concurrent runs.** Nothing stops a second `call` while one is pending: both run, each invalidates after its own success, and the state follows the last one started (a late result of the first doesn't replace it). Disable the button while `isPending` when a double write is wrong.
- **A page that goes away.** The provider is kept alive until the write completes, even if its page is popped meanwhile, so the write still finishes and still refreshes the data. The state is only written while the provider is alive, so a submission that finishes after the page, or the whole container, is gone doesn't throw. After an `await` in a callback, check `context.mounted` before navigating.
- **Navigation is the caller's.** An action returns what it wrote and doesn't navigate:

  ```dart
  final done = await RefundRoute.submit(ref, id: id, input: input);
  if (context.mounted) ReceiptRoute(id: id).go(context);
  ```

**In a section's folder.** An `action.dart` in a folder with a `layout.dart` and no `page.dart` writes to the section. Its helpers are on the section's handle (`TeamsTeamIdSection.addMember(ref, teamId: 'acme', input: 'carol')`), and what it invalidates by default is the section's own data and the sections above it. A section with no `data.dart` gets a handle for its actions alone (`ShopSection`), named like [any section's](data.md#section-data).

**Scaffold and diagnostics.** `fsp new 'orders/[id]/refund' --action` scaffolds one, with the path's segments and an `Object?` input to replace with your own type. `fsp routes` tags the route `action`. The generator reports, with a code frame:

- an `action.dart` with no `page.dart`, and no `layout.dart` of a page-less folder, beside it, or with no function in it that takes a `Ref` first;
- a missing `input`, or one that is positional, not `required` or untyped;
- a parameter that is neither a segment, a query parameter nor `input`, a missing return type, a `Future`, `FutureOr` or (since 0.25.0) `Stream` with no type argument;
- an `invalidates` that is not a `const` list literal of names, a name that is neither a typed route nor a section handle or has no `data.dart`, and a key of the data it invalidates that the action doesn't take;
- helper names that collide;
- since 0.8.1, a `form()`, `validate()` or `optimistic()` that doesn't fit its action (see below and [Forms](forms.md));
- since 0.25.0, a `form()`, `steps` or `optimistic()` beside a [streaming action](#streaming-actions-streamt), which are not built for one.

### `validate()` and `FieldErrors`

Since 0.8.1. `validate()`, `optimistic()` and, with the [`fespalier_forms`](forms.md) package, `form()` are _companion functions_ in the `action.dart` of the action they belong to, found by name. For the action called `action` the companion is the role itself; for any other action, say `approve`, it is `approveValidate`, `approveOptimistic` and `approveForm`. A companion is never read as an action, even when it takes a `Ref` (that is an error). `validate()` and `optimistic()` need nothing but `fespalier`; `form()` needs the package, and is on [its own page](forms.md).

```dart
// lib/app/(account)/nickname/action.dart
typedef NicknameFields = ({String nickname, int? age, bool newsletter});

/// Checked on the device before the action runs, and live in a form after a first submit.
FieldErrors? validate(NicknameFields input) => FieldErrors({
  if (input.nickname.trim().isEmpty) 'nickname': 'Enter a nickname',
  if (input.age case final age? when age < 13) 'age': 'You must be 13 or older',
});

/// The server has the last word: it can throw `FieldErrors({'nickname': 'That nickname is taken'})`.
Future<Profile> action(Ref ref, {required NicknameFields input}) => …;
```

- **`validate()`** is `FieldErrors? validate(Input input)`. It takes no `Ref` (a check the device can make) and does not need a record input. It runs **inside the action's provider, before the action**, so `submit`, `useAction`'s `call` and a test through the provider are refused the same way: the write never starts, there is no loading state, and the `FieldErrors` is in `state` and `fieldErrors`. It returns `null` (or an empty `FieldErrors`) for a valid input.
- **`FieldErrors`** is what an action, or `validate()`, throws or returns to say which fields of its input are wrong: `FieldErrors({'nickname': 'That nickname is taken'}, message: 'Could not save')`. The keys are the names of the input's fields; `message` is what is wrong with the input as a whole. `useAction`'s `fieldErrors` is the one the last run failed with, or `null`.
- **A check that needs the server** belongs in the action, which throws a `FieldErrors`. The [HTTP package](http.md) maps a server's validation answer to one.
- **A form** (`form()`, `useForm`, typed fields, a pending state) shows each message under its field. It moved to the `fespalier_forms` package in 0.11.0: see [Forms](forms.md).

**Telemetry** (since 0.18.0): an action that `validate()` refused, or that threw `FieldErrors`, ends its span with `fespalier.action.invalid` set to `true`, and its `fespalier.action.result` stays `error`. A form that stops a submit before the action runs makes no span. [Telemetry conventions](telemetry-conventions.md#telemetry-conventions) has the names.

### Optimistic updates: `optimistic()`

Since 0.8.1. `T optimistic(T current, Input input)` is what the page shows of one `data.dart` from the moment a write starts until the server's answer is in:

```dart
// lib/app/teams/$teamId/action.dart
Team addMemberOptimistic(Team team, String input) =>
    Team(team.name, [...team.members, input]);

Future<void> addMember(Ref ref, {required String teamId, required String input}) async => …;
```

- **The target** is the `data.dart` the action invalidates whose type is `T`. When several match, the folder's own data comes first, then the sections above it (innermost first), then the rest of `invalidates` in the order listed. The action has to invalidate it (the default set does; an explicit `invalidates` must list it), or that is an error: a patch over data that never loads again would have no end. Only the target is patched; other invalidated data just reloads.
- **The sequence.** The patch is shown from the start of the write. On a failure it is removed (the rollback). On a success it **stays over the old value until the invalidated data has loaded again**, then the server's value replaces it: no frame shows the old value in between. This holds with `keep_previous: false` too: while a write that patched the data settles, `DataView` does not show `loading.dart`, because the page has already shown the result.
- **Concurrent writes** apply oldest first; a failure removes only its own patch.
- **Which reads are patched.** `DataView`, `SectionView` (the layout and every page that takes the section's data by type) and the typed `XRoute.watch` / `XSection.watch` show the patched value. `XRoute.data` (the provider), `read`, `refresh`, `prefetch`, `preload` and `AppRoutes.dataAt` give the server's value. A dependency-triggered reload (`AsyncLoading` with a value) is returned unpatched by `watch`, and still patched in `DataView`.
- **The patch holds until the data loads again, even to an equal value**: the reload ends it, not a comparison. A patch that throws is reported through `FlutterError.reportError` (context `while applying an optimistic() patch`) and skipped; it never turns into `error.dart`.
- If the page leaves in the middle of a write, the write still finishes and still invalidates.

**Telemetry** (since 0.18.0): when the write fails and its patch is taken back, the action's span says `fespalier.action.rolled_back` is `true`; a write that works says `false`. An action with no shown patch has no such attribute.

### Streaming actions: `Stream<T>`

Since 0.25.0. An `action.dart` function that returns `Stream<T>` is a _streaming action_: a write whose answer comes in pieces, such as a text written word by word (a language model's answer), the progress of an import, or the steps of a long job. Each item is shown as it arrives, and the user can stop it.

```dart
// lib/app/docs/new/action.dart
FieldErrors? draftValidate(String input) => input.trim().isEmpty
    ? const FieldErrors({'topic': 'Type what the doc is about first'})
    : null;

/// Each item is the text so far.
Stream<String> draft(Ref ref, {required String input}) =>
    ref.read(draftWriterProvider).write(input);
```

```dart
// in a HookConsumerWidget (or any ConsumerWidget)
final draft = NewDocRoute.useDraft(ref);
if (draft.isPending)
  TextButton(onPressed: draft.cancel, child: const Text('Stop'))
else
  TextButton(onPressed: () => draft.call(topic), child: const Text('Draft')),
if (draft.value case final text?) Text(text),
```

- **The members** are an action's: the provider (`NewDocRoute.draftAction`, a `streamActionProvider`, or a `streamActionFamily` for an action with keys), the one-shot helper (`NewDocRoute.draft(ref, input: ...)`, which completes with the last item or throws what the stream threw) and the hook (`NewDocRoute.useDraft(ref)`).
- **The state** is a `StreamActionState<T>`, not an `AsyncValue` (Riverpod has no public "loading, with a value"): `StreamIdle` until it runs, `StreamRunning` while items come, then `StreamDone` when the stream ended, `StreamFailed` (with `error` and `stackTrace`) when it threw, or `StreamCancelled` when the run was stopped. Every state has `latest`, the last item of the run (null before the first), and `count`, how many came. Each item is a new state, so the page rebuilds on every item, even one equal to the item before it.
- **The handle** (`StreamActionHandle`) has `state`, `value` (`state.latest`), `isPending`, `hasError`, `fieldErrors`, `call(input)` (completes with the last item, or with `null` when the run failed: the error is in `state`), `cancel()` and `reset()` (stops the run, then idle).
- **`validate()` runs first**, as for any action: an input it refuses never starts the stream, and its `FieldErrors` are the failed state's. `FieldErrors` the stream throws end it the same way.
- **The last run wins.** A `call` while a run is in progress stops that run (it ends cancelled, and its `Future` completes with what it had) and starts the new one; the state is the new run's.
- **A page that goes away stops the run.** A run started from the hook lives while something watches the provider: when the page is popped, the provider is disposed and the stream's subscription is cancelled, which aborts what it was reading (a `fespalier_stream` connection, or any client that stops when its stream is cancelled). The one-shot helper (`draft`, `submit`) holds the provider alive until the stream ends instead, like a `Future` action, so a write that must finish uses it. `cancel()` stops a held run too.
- **After the run.** When the stream ends, and when a run is stopped after at least one item, the data the action made stale is invalidated (the same default set, or `invalidates`). A failed run invalidates nothing, and neither does a run stopped because its page went away: its provider is gone. A streaming action is never retried, and its errors never reach `error.dart`.
- **Not built.** A `form()`, `const steps` or `optimistic()` beside a streaming action is an error that says so: return a `Future<T>` for those. `validate()` is fine.
- **Within telemetry.** The stream is listened to inside the action's span, so an HTTP span made while it runs is its child. The span ends once, with `fespalier.action.result` `ok`, `error` or `cancelled`, and `fespalier.action.items`, the count of items ([Telemetry conventions](telemetry-conventions.md#telemetry-conventions)); the items are never recorded. In DevTools the run is `running`, then `done` (a cancelled run too) or `error`, with the last item as its result: one entry per run, not per item.
- **A hot reload** keeps working while the action stays a stream; turning a `Future` action into a `Stream` one (or back) changes its provider, so `fsp dev` restarts the app.
- **No timer.** fespalier starts no timer and no listener for it: the one subscription is the one on the stream your function returned.

UNCHECKED on a device: that popping the page during a run cancels the request on a phone's network, that the keyboard stays usable while the text grows under a field, and how screen readers read a text that changes on every item (a `Text` that grows may be read again at each change).

The `examples/features` app drafts a doc this way on `/docs/new`. Streaming responses in general are on [Streaming](streaming.md).
