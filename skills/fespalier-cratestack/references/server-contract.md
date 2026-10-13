# The server's contract: idempotency, the answer table and row sync

Since 0.10.0. What an app that queues calls needs from its CrateStack server, and what the package does with each
answer. The guarantees below are from
[cratestack.dev/guides/idempotency](https://cratestack.dev/guides/idempotency); CrateStack is pre-1.0, so re-read them
for the version you run.

## What the server's idempotency layer guarantees

- **Opt-in, for mutations.** The `Idempotency-Key` header is opt-in and applies to mutations. The package builds the key
  as `<intent id>#<attempt>` and sends the stored bytes every time.
- **A namespace.** The key lives in a namespace: the **verified principal**, else a hash of the `Authorization` header,
  else the peer address. With none of these the layer answers `412`.
- **A replay** of a finished request returns the stored answer with `Idempotency-Replayed: true`.
- **A key still being answered** gets `409` with `Retry-After: 1`. The package reads that as "same key, try later"
  (`CrateStackInFlight`).
- **The same key with a different body** is `422` `VALIDATION_ERROR` with a message starting
  `idempotency_key_conflict`. That is a bug in the caller (the stored body changed): the intent is `failed`, and it is
  **never** shown as a form error.
- **A TTL bounds the reservation.** An intent never expires on the device, so the server's TTL is the only bound on
  "never": a call that waits longer than the TTL may run again.

## Why the namespace is the whole game

With the `Authorization` fallback, **a token refresh between two attempts changes the namespace**. The replay of a call
whose answer was lost is then a new request and **runs the call a second time**. `fespalier_auth` refreshes lazily and a
`401` keeps the same key, so this does happen: an intent sent with an expired token is answered `401`, then retried under
the refreshed token and the same key.

- Configure the server's idempotency layer to use the **verified principal** (the docs call it the first choice since
  CrateStack 0.14.0).
- **Do not queue a call whose double run matters** (a payment, a transfer) against a server that cannot. Keep it
  online-only, or make the call itself idempotent on a business key (an id the client generates and the server checks).
- Whether a deployment namespaces by principal is the server's configuration, not something the client can verify.
  Treat it as a requirement to confirm, in writing, before the first queued write ships.

## What the package does with each answer

`CrateStackFailure.fromEnvelope` (RPC, an envelope with `code` and `message`) and `CrateStackFailure.fromResponse`
(a Dio response, with or without an envelope) classify, then the queue acts:

| The server answers                                                                  | Classified as               | The intent                              |
| ----------------------------------------------------------------------------------- | --------------------------- | --------------------------------------- |
| success                                                                             |                             | deleted, `touches` bumped               |
| no answer (network, timeout, gateway or captive-portal page)                        | `CrateStackOffline`         | `pending`, same key                     |
| `409` + `Retry-After`, or `409` `TRANSACTION_ABORTED` (the server did not store it) | `CrateStackInFlight`        | `pending`, same key                     |
| `401`                                                                               | `CrateStackUnauthenticated` | `pending`, same key                     |
| `5xx`, an envelope that cannot be read                                              | `CrateStackUnavailable`     | `pending`, **next key**, `failures + 1` |
| `422` `idempotency_key_conflict`                                                    | refused                     | `failed`                                |
| `409` without `Retry-After` and not `TRANSACTION_ABORTED`                           | `CrateStackConflict`        | `conflict` (the person resolves it)     |
| any other `4xx`                                                                     | `CrateStackRefused`         | `failed`, the wire code only            |

A `5xx` takes the **next** key because the server may have stored the failure and would replay it under the old one.
Without an envelope (`fromResponse`): `text/html` of any status, or `502`, `503`, `504`, `511`, is offline; a bare `401`
is unauthenticated; a bare `409` is a conflict unless `Retry-After` is there; a bare `4xx` is refused with the code
`HTTP_<status>`; a bare `5xx` (a `500` included) is unavailable, **not offline**. The refusal keeps the wire `code` and
`status`; its message and `details` are the server's and are never stored, logged or sent to telemetry.

## What `RowSync`'s two procedures must do

CrateStack has no sync protocol, so the app adds two procedures to its schema (say `syncPush` and `syncPull`) and a
`RowSync` over them (`fespalier-offline`, [`owned-rows-and-sync.md`](../../fespalier-offline/references/owned-rows-and-sync.md)).

- **`syncPush(rows)`** merges each row **per field**, by the stamp, with the same rule as the device (the greater stamp
  wins; equal stamps are the same write; the merge is commutative, associative and idempotent), and answers each row as
  it now stands (`accepted`) or the reason it refused it (`rejected`, a wire `code` and the server's current row).
- **It writes through the model layer**, so the schema's policies still apply to what a device pushes: a refused row is
  rolled back on the device, out loud.
- **`syncPull(collection, cursor)`** answers the rows changed since the cursor, with every field's stamp, a `next`
  cursor and whether more follow.
- The two calls are repeat-safe by the merge, not by an idempotency key: send them with `transport.send(call)` and no key.
- Stamps are the devices' hybrid logical clock (wall milliseconds, a counter, a node id); the server keeps each field's
  stamp with it, and returns them in both procedures.

## Where the code is

`packages/fespalier_cratestack/lib/src/errors.dart` (`fromEnvelope`, `fromResponse`), `intent_queue.dart` (`drain`), and
the package's `test/intents_test.dart`, which is the table above as a test.
