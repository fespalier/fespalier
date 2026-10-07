# Leaving a page: `leave.dart`

Since 0.11.0. A `leave.dart` is asked before its folder's page goes: a form with unsaved changes, a
call in progress. `fsp gen` emits it as the `onExit` of the folder's `GoRoute`, wraps the page in
`leaveScope` and so makes the back gestures ask too. Full text: `docs/navigation.md`, "Leaving a page:
`leave.dart`".

```dart
// lib/app/orders/$id/edit/leave.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';

/// Asked before /orders/:id/edit goes. True lets it go; false keeps it.
LeaveResult leave(BuildContext context, Ref ref, {required int id, required PageLeave page}) async {
  if (!page.isDirty) return true; // stays sync when you return a bool directly
  final ok = await showModalBottomSheet<bool>(context: context, builder: (c) => DiscardSheet());
  return ok ?? false;
}
```

`fsp new 'orders/[id]/edit' --leave` writes it.

## The file

- **Return type:** `LeaveResult` (`FutureOr<bool>`; no `dart:async` needed), `FutureOr<bool>`, `Future<bool>` or
  `bool`. `true` lets the page go, `false` keeps it.
- **Positional parameters**, each optional and in this order: `BuildContext context`, `Ref ref`. The context is the
  **root navigator's** (go_router's), so `showModalBottomSheet(context: context)` opens above every shell. The `Ref` is a
  throwaway provider's, kept open until the answer is in, so it is valid after an `await`. `WidgetRef` and
  `ProviderContainer` are errors.
- **Named parameters**, bound like a guard's: the folder's segments and those above it, query (the folder route's),
  `Uri uri`, typed `extra` (as a guard takes it) and `PageLeave page`, by type and name. `TypedLocation` is not bound.
- **One folder, one page.** It is **not inherited**: go_router already asks a parent's `onExit` when the parent's own
  match exits (`/orders/1/edit` to `/orders/1` asks `edit` only; to `/home` asks `edit`, then `$id`). A `nest = false`
  sibling exits its parent's match, so the parent's `leave.dart` is asked. The folder needs a `page.dart` (a
  layout's shell has no `onExit` in go_router) and must not be a `redirect.dart` route.

## `PageLeave`, `LeaveSource`, `LeaveScope`

- `PageLeave`: `state` (the route's `GoRouterState`), `isDirty` (any registered source is dirty), `canKeep` (some source
  can save a draft), `keep()` (each source saves its draft), `discard()` (each drops it). A page with nothing registered
  is clean and cannot keep.
- `LeaveSource` (a `Listenable`): `isDirty`, `canKeep`, `keep()`, `discard()`. Core knows nothing of forms:
  a `useForm` of `fespalier_forms` registers its form by itself (since 0.11.0; `leaveIfClean(context, ref, page)` is
  the whole `leave()` that asks in a bottom sheet: `fespalier-data`, `references/forms.md`, "Leaving with unsaved
  changes"); register your own for anything else (nothing else registers one, and a page with none is always clean).
  A source that turns dirty or clean must notify.
- `LeaveScope.maybeOf(context)?.onBack(() => handled)` lets a source take the system back itself (a step of a
  multi-page form): handlers run newest first on Android's back and `Navigator.maybePop`, the first that returns true
  stops the pop and `leave()`. Not consulted on the first page of a navigator; while one is registered the iOS swipe is off.
- `LeaveScope.maybeOf(context)?.register(source)` (null in a page without a `leave.dart`) registers a source and returns
  what unregisters it; it is safe during `build`.
- The registry is keyed by `pageInstanceId(state)`, never by the remount key, so a `remount` page keeps asking about the
  form its rebuilt subtree registers.

## What is asked, and what is not

**Asked:** `go`, `replace`, `pushReplacement`, `pop`, `context.pop` and `Navigator.pop` of the page; Android back
(through `PopScope` and `GoRouter.pop`, or go_router's root fallback, where `true` closes the app); the web's back and
forward (refused: the address bar is reset to the page, a new history entry, forward history lost); a guard's refresh or
redirect, **including a sign-out redirect**; leaving a tab layout, for the **active** tab's pages only. go_router's
`onEnter` and guards run first at parse time; `onExit` runs after.

**Not asked:** a tab switch (fespalier parks; go_router would ask); a parked tab's pages when the whole layout leaves (use
drafts); a query-only change (also `replace` of a pushed page with itself at another query); a dialog or sheet (a pageless route) on top; `refresh()` with the same match list; a
`redirect.dart` route; layouts; an imperative `Navigator.push` or replace outside go_router; process kill, hot restart,
`router.dispose()`; the page's own `PopScope(canPop: false)`, which wins for system back. `/c/1` to `/c/2` is asked,
whatever `remount` says. `leave.dart` is imported eagerly (never `deferred`), so what it imports leaves the deferred
chunk. While an async-guarded `go` is parsing, a pop is judged against that destination.

**Known gap:** on go_router 17.0 to 17.3 (Flutter below 3.38) popping a whole `ShellRoute` page off the root navigator
skips the leaf's `leave()` (fixed in 17.4.0).

## How it answers

1. `await leaveWithoutAsking(router, () => navigate())` (navigate may be async; it always returns a `Future`) lets pages go
   while it runs and its `Future` is pending, then waits for fespalier's guards to settle (container `pump`, async guards)
   and lets their `refresh` through (kept until the router commits it, or until another navigation; a guard that never answers holds it until then), plus one requested commit not yet applied (an identity ticket and a one-shot
   listener); it never covers a pop after the window, a `navigate` that requests nothing or a request that commits
   nothing (a failed sign-out asks again). Wrap
   sign-out in it, or check auth in `leave()`.
2. A tab switch goes through without calling `leave()`, unless a route it reaches that the page is not already
   under has a `redirect:` (a guard of that tab's own folder): that may take the navigation out of the shell, so it asks. A guard of the tabs' folder or above runs on the tab shell (since 0.11.0), so it never does: if its answer changes at the switch itself and it redirects out of the tab layout, the page goes without being asked. A hand-written
   top-level `redirect:` cannot be seen.
3. One prompt at a time: a second ask of the same page instance waits for the first and answers `true` only if the
   page is still there afterwards (a double pop completes once; a back joining a `go`'s prompt never closes the app; a
   newer `go` joining an earlier one's prompt is refused: the first navigation wins). A
   `leave()` whose `Future` never completes holds every later ask. `leave()` must `read`, not `watch`: its first
   answer stands.
4. `leave()` runs with its `Ref` and the page's `PageLeave`. A throw, sync or async, is reported with
   `FlutterError.reportError` (context `while running leave() of <file>`) and the page goes: a broken `leave()` never traps
   the user. A segment that does not parse lets the page go (it shows not-found).
5. A synchronous answer stays synchronous: no `Future`, no microtask of fespalier's.

## The back gestures

`leaveScope` wraps the page in a `PopScope`. On a page whose route can pop, `canPop` is true only when the page has at
least one source and every source is clean; otherwise the back becomes `GoRouter.pop`, which asks `leave()`. So the iOS
edge swipe is **off** while there is no source or a source is dirty (and works when all are clean), Android's predictive
back shows no preview while blocked, and Android back always reaches `leave()`. On the bottom page of a navigator
`canPop` is true, so go_router's own fallback asks `leave()`.

## Tests

`pumpRouter` (`package:fespalier/testing.dart`) is enough: `router.go(...)`, then pump, and look at what stayed. The
system back is `handlePlatformMessage('flutter/navigation', JSONMethodCodec().encodeMethodCall(MethodCall('popRoute')), ...)`.
`packages/fespalier/test/leave_test.dart` and `examples/features/test/leave_test.dart` have both. A test of the
`ShellRoute` pop case must skip itself below go_router 17.4.

Diagnostics: [`fespalier-troubleshooting`](../../fespalier-troubleshooting/references/diagnostics-data-and-hooks.md#leavedart).
