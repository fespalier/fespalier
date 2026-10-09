# Intents: the queue, the answer table and the sign-out wipe

Since 0.10.0. An `Intent` is one queued mutation: a decision only the server makes. `IntentQueue` (the `intentQueue`
provider, per account) saves it, sends it, and keeps it until the server decides or the person discards it. It never
retries by itself (no timer, no backoff): the next `drain()`, which the sync's triggers run, sends it again.

## What an intent holds

`id` (128 random bits, hex), `seq` (the order on this device), `call` (a `RpcCall` or `RestCall`), `createdAt`,
`subject` (`order:42`: it waits behind an undecided earlier intent of the same subject), `touches` (revision tags bumped
when it is accepted), `attempt` (numbers the key: `<id>#<attempt>`), `status`, `reason` (the wire code of a refusal or a
conflict, never the server's message) and `failures` (stored `5xx` answers).

| `IntentStatus` | Meaning                                                                                                        |
| -------------- | -------------------------------------------------------------------------------------------------------------- |
| `pending`      | Not decided: never sent, or sent with no answer. Sent again under the same key                                 |
| `sent`         | Being sent right now. It is saved before the send, so a crash leaves it "maybe landed": the same key next time |
| `failed`       | Refused by the server. `reason` is the wire code. Kept until the person discards it                            |
| `conflict`     | The server answered a conflict (a stale version). Kept until the person resolves or discards it                |

`undecided` is `pending` or `sent`; `pendingIntents` lists only those.

## What a send does with each answer

`submit` and `drain` classify what the transport throws with `crateStackErrors` (your reader first, then
`DioFailures.read`), then:

| The server answers                                                                  | Classified as               | The intent                                |
| ----------------------------------------------------------------------------------- | --------------------------- | ----------------------------------------- |
| success                                                                             |                             | deleted, `touches` bumped, `Accepted`     |
| no answer (network, timeout, gateway or captive-portal page)                        | `CrateStackOffline`         | `pending`, same key                       |
| `409` + `Retry-After`, or `409` `TRANSACTION_ABORTED` (the server did not store it) | `CrateStackInFlight`        | `pending`, same key                       |
| `401`                                                                               | `CrateStackUnauthenticated` | `pending`, same key                       |
| `5xx`, an envelope that cannot be read                                              | `CrateStackUnavailable`     | `pending`, **next key**, `failures + 1`   |
| `422` `idempotency_key_conflict`                                                    | refused                     | `failed` (a bug: the stored body changed) |
| `409` without `Retry-After` and not `TRANSACTION_ABORTED`                           | `CrateStackConflict`        | `conflict` (the person resolves it)       |
| any other `4xx`                                                                     | `CrateStackRefused`         | `failed`, the wire code only              |
| an error no reader knows                                                            | none                        | kept `pending` under its key, debug line  |

`submit` returns `Queued` for the not-decided rows, and **throws** the refusal on the spot (`CrateStackRefused`,
`CrateStackConflict`, or `FieldErrors` through `withCrateStackFieldErrors`) **without keeping anything**: the person is
on the screen that asked. `drain` never throws for a call's failure. `CrateStackCancelled` (the provider that made the
request was disposed) is `Queued` too.

The server side of this (what `Idempotency-Replayed`, `409 Retry-After` and `422` mean, and why the namespace of the
key matters) is in [`fespalier-cratestack`](../../fespalier-cratestack/references/server-contract.md).

## Operating the queue

- `ref.read(intentQueue).list()` every intent of the account, oldest first (empty while signed out);
  `pendingIntents(subject)` only the undecided ones, for a banner and a row's "cancelling...";
  `discard(id)` deletes one (the person gave up on a `failed` or `conflict` one); `clear()` deletes the account's.
- `drain()` sends every pending intent, oldest first, one at a time, **skipping a subject with an undecided earlier
  one**, and stops at the first `CrateStackOffline` and when the account changes. It returns a `DrainReport`
  (`accepted`, `failed`, `conflicts`, `retained`, `offline`, `reachedServer`).
- **`Intent` is also Flutter's `Intent`** (`widgets/actions.dart`): a file that imports both
  `package:flutter/material.dart` and `fespalier_cratestack.dart` and names `Intent` gets `ambiguous_import`. Hide
  one (`import 'package:flutter/material.dart' hide Intent;`) or prefix the other.
- A `failed` or `conflict` intent is not undecided, so **show it yourself**: nothing in `pendingIntents` says so.

```dart
// lib/problems.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:flutter/material.dart' hide Intent; // Flutter has an Intent of its own

/// Intents the server refused or answered with a conflict: kept until the person discards them.
final problems = FutureProvider.autoDispose<List<Intent>>((ref) async {
  ref.watch(crateStackRevision(intentsTag)); // bumped whenever an intent is saved, changed or removed
  final all = await ref.read(intentQueue).list();
  return [
    for (final intent in all)
      if (!intent.undecided) intent,
  ];
});

class Problems extends ConsumerWidget {
  const Problems({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    children: [
      for (final intent in ref.watch(problems).value ?? const <Intent>[])
        ListTile(
          title: Text('${intent.call}: ${intent.status.name} (${intent.reason})'),
          trailing: TextButton(
            onPressed: () => ref.read(intentQueue).discard(intent.id),
            child: const Text('Discard'),
          ),
        ),
    ],
  );
}
```

## Validation errors become form errors

`submit(...).withCrateStackFieldErrors(ref, fieldName: ...)` turns a `422` `VALIDATION_ERROR` into fespalier's
`FieldErrors`, like `withFieldErrors` in `fespalier_dio` (and, for `package:http`, `fespalier_http` since 0.15.0), on the action's own `Future`. CrateStack documents the
message (`field 'email' is not a valid email address`) but **no structure for `details`**, so the package reads `details`
when it is a map of field to message (or a list of strings) or a list of `{field|path, message}`, then the documented
message, then falls back to `FieldErrors({}, message: message)`. **That `details` shape is an assumption**; anything
else is tolerated, not an error. `fieldName: (key) => ...` maps the server's key to your form's field name. A message
starting `idempotency_key_conflict` is never a field error. It reads the errors with the app's `crateStackErrors`.

```dart
// lib/app/profile/action.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';

/// A rename is the server's call too, and a bad name comes back under the field.
Future<IntentOutcome<String>> rename(Ref ref, {required String input}) => ref
    .read(intentQueue)
    .submit(
      RpcCall('renameUser', {'display_name': input}),
      subject: 'profile',
      touches: const {'profile'},
      decode: (output) => '$output',
    )
    .withCrateStackFieldErrors(ref, fieldName: (key) => key == 'display_name' ? 'name' : key);
```

```dart
// lib/app/profile/page.dart
import 'package:flutter/material.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) => const Text('Profile');
}
```

## The sign-out wipe

`ref.read(crateStackAccount).clear()` deletes the account's intents, owned rows, sync cursors and cached reads (the
device's node id stays: it names the device, not a person). Sending A's intent under B's session is worse than losing
it, so **a sign-out calls it before the session ends**. `clear({String? scope})` defaults to the current
`crateStackScope`; `fespalier_auth`'s sign-out is synchronous, so the scope is **already null** after `signOut()` and a
late `clear()` does nothing: call it first, or pass the account you left. Every operation captures its account and a
wipe generation, so a call in the air when the account changes is applied to **that** account's store only and never
brings a wiped intent back.

## Where the code is

`packages/fespalier_cratestack/lib/src/intent.dart`, `intent_queue.dart` (the table above is its `drain`),
`errors.dart`, `field_errors.dart`, `scope.dart` (`CrateStackAccount`, `WipeGenerations`); the package's
`test/intents_test.dart` is the answer table as a test.
