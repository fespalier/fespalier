# Coming from RIBs

[RIBs](https://github.com/uber/RIBs) is the architecture framework Uber built for its iOS and Android apps. Its name
is short for Router, Interactor and Builder, and it is Apache-2.0 (the iOS half now lives in
[uber/RIBs-iOS](https://github.com/uber/RIBs-iOS)). This page is for a team that knows RIBs and is building a Flutter
app with fespalier. It covers what each part of a RIB becomes, where the two designs disagree, and how to move a
feature over.

fespalier is not a RIBs port and has no RIB type. What maps is the ideas: a RIB's class usually becomes a file kind
under `lib/app/`, a plain function or widget that `fsp` wires up.

## The short version

RIBs builds an app as a tree of business-logic scopes. Each scope's interactor decides which children to attach and
its router attaches them, and a scope does not need a view. In the words of its README, business logic drives the app, not the view tree.

fespalier builds an app as a tree of folders under `lib/app/`, and the **location** decides what is on screen. State
reaches the tree through guards: a `guard.dart` watches it and redirects when the answer changes. Most of what a RIB
does has a direct counterpart, and the part that has none (a scope with no URL) is a Riverpod provider. See
[State that outlives a page](#state-that-outlives-a-page).

## Part by part

| In RIBs                                                                                                      | In fespalier                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| ------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Builder**: makes the RIB and its children's builders; the only part that knows the DI system               | The generator. `fsp` reads each file's constructor and writes the router into `lib/app.g.dart`, so nobody writes a builder. See [How parameters are filled](file-kinds.md#how-parameters-are-filled).                                                                                                                                                                                                                                                       |
| **Component**: the dependencies a RIB gets from its parent, and the ones it owns                             | Riverpod providers. A provider is a dependency, `startup()` can return the app's overrides ([`startup.dart`](app-startup.md)), and a test overrides what it fakes. What a whole subtree shares is a section `data.dart` ([Section data](data.md#section-data)).                                                                                                                                                                                             |
| **Interactor**: the business logic, active between attach and detach (`didBecomeActive`, `willResignActive`) | `data.dart` (what the route loads), `action.dart` (its writes, with pending and error state) and `observe.dart` (`onEnter`, `onLeave`, `onFocus`: side effects at the edges of a page's life; a layout or a section has no hooks, so a viewless RIB's setup lives in its section `data.dart` or a provider, torn down in `ref.onDispose`). See [File kinds](file-kinds.md#at-a-glance) and [Route lifecycle](observability.md#route-lifecycle-observedart). |
| **Router**: attaches and detaches children from what the interactor decides                                  | `guard.dart`. A guard watches state and returns a location to go to instead, and it runs again when what it watches changes (a `redirect.dart` runs once per navigation and watches nothing). `layout.dart` holds the children, as a shell or as tabs. See [Guards](guards.md).                                                                                                                                                                             |
| **Presenter**: turns business models into view models                                                        | Usually nothing. A page takes its typed data as a constructor parameter. When the shape needs changing, a `data.dart` returns the shape the page wants, or a provider maps it.                                                                                                                                                                                                                                                                              |
| **View(Controller)**: builds the UI                                                                          | `page.dart`, a plain widget (or a function) whose constructor says what it needs.                                                                                                                                                                                                                                                                                                                                                                           |
| **Viewless RIB**                                                                                             | A `(group)` folder: it adds nothing to the URL and holds a guard or a layout for the routes in it, and section data when it has no `page.dart` of its own.                                                                                                                                                                                                                                                                                                  |
| **Parent to child**: a `build()` parameter, or an Rx stream                                                  | Segments and query parameters (typed constructor parameters), a section's data, and providers.                                                                                                                                                                                                                                                                                                                                                              |
| **Child to parent**: a listener interface the parent implements                                              | An `action.dart` the child calls, a provider the parent watches, or a typed navigation (`ProductRoute(id: 42).go(context)`).                                                                                                                                                                                                                                                                                                                                |
| **Workflow**: a deep link as steps that wait for each RIB                                                    | A URL. One navigation builds the whole stack, and guards gate it. See [Deep links instead of workflows](#deep-links-instead-of-workflows).                                                                                                                                                                                                                                                                                                                  |
| **Code generation**: Xcode templates and an IntelliJ plugin                                                  | `fsp new` scaffolds a folder and its file kinds (`fsp new 'products/[id]' --data --action --guard`), and `fsp gen`, `fsp watch` and `fsp dev` keep `lib/app.g.dart` current. The editor plugins show `fsp`'s diagnostics. See [CLI reference](cli.md).                                                                                                                                                                                                      |
| **Unit tests of an interactor** with mocked dependencies                                                     | A route's data and actions are providers, so a test needs no widget: a `ProviderContainer` with overrides, then `container.read(RefundRoute.action(1).notifier).call(input)`. `pumpRouter` runs the real router in a widget test, `fsp test` writes a smoke test per route, and the companion packages ship fakes in their `testing.dart`. See [Testing](testing.md).                                                                                       |
| **Per-RIB events** (Android's `RibEvents`: attach, detach, action durations)                                 | Telemetry per route pattern: spans for each navigation, guard, data load and action ([Observability](observability.md)), and screen views with consent ([Analytics](analytics.md)).                                                                                                                                                                                                                                                                         |

## Signed in or out: the tutorial, as folders

RIBs' tutorial app has a root RIB that attaches `LoggedOut`. After sign-in, it detaches `LoggedOut` and attaches a
viewless `LoggedIn` RIB, which switches between `OffGame` and the game. The same app in fespalier is a folder tree
and one guard:

```text
lib/app/
  login/page.dart            the LoggedOut screen
  (signed-in)/               the LoggedIn scope: a group with no page.dart, so nothing is added to the URLs
    guard.dart               signed out? go to /login?from=…
    layout.dart              what every signed-in screen shares
    data.dart                optional: what LoggedIn held (the players, the scores), loaded once
    (lobby)/page.dart        → /       OffGame
    game/page.dart           → /game   the game
```

```dart
// lib/app/(signed-in)/guard.dart
GuardResult guard(Ref ref, {required Uri uri}) =>
    ref.watch(session) ? null : LoginRoute(from: uri.toString()).location;
```

- **Signing out** needs no routing code. The guard watches the session, so when it changes the router runs the
  redirects again and moves the user to `/login` from whatever page they were on (a pushed page can stay:
  [#258](https://github.com/fespalier/fespalier/issues/258)).
- **Signing in** is the login page's to finish: `context.go(returnTo(from))` sends the user where they were going
  ([Sending people back](guards.md#sending-people-back)).
- **Starting a game** is a navigation, `const GameRoute().go(context)`, and the game ending is another one, back to
  `const LobbyRoute()`. Each state of the scope has a URL, so links and the browser's address bar work. What
  `LoggedIn` held for both screens is the group's section `data.dart`, which both pages can take by type.
- With `fespalier_auth`, the guard is one line: `requireSignedIn(ref, uri, signIn: (from) => LoginRoute(from: from))`
  ([Authentication](auth.md)).

## Deep links instead of workflows

In RIBs, a deep link is a workflow: a chain of steps, each of which waits for the scope it acts on to be ready (the
tutorial's waits for sign-in, then launches the game). In fespalier, a deep link is a location. `/game` opens the
game, the `(signed-in)` guard sends a signed-out user to `/login?from=%2Fgame`, and `returnTo(from)` brings them back
after sign-in. There is no workflow code: the URL describes the whole stack, and the guards decide whether it may be shown.

Taps that do not start as a URL map onto a typed route, cold start included, through adapters:
[Push notifications](push.md) (`fespalier_push`) and [Shortcuts and widgets](launch.md) (`fespalier_launch`).

## State that outlives a page

A RIB can outlive any single screen: a trip in progress, say, spans several views while one interactor owns it. In
fespalier, pick the shape that matches the scope:

- **A folder's lifetime: section data.** A `data.dart` beside a `layout.dart` in a folder with no `page.dart` is the
  data of the whole section. The layout waits for it, the pages below take it by type, and moving between those pages
  does not load it again ([Section data](data.md#section-data)). `trips/$tripId/` is the trip's scope.
- **One page on a navigator: page-instance providers.** `fespalier_riverpod` keys a provider by the page instance, so
  the same route pushed twice holds two states. The state is disposed after that page's last widget goes
  ([Providers per page instance](data.md#providers-per-page-instance-fespalier_riverpod)).
- **No folder at all: a provider.** State that belongs to no part of the tree, such as the session or a cart, is a
  Riverpod provider that guards and pages watch.
- **Steps on one screen: a state machine.** A flow that stays on one screen as it moves through states is a
  `Notifier` in that page. RIBs would make each step a RIB. If each step deserves a URL (back, a link, a reload),
  make each one a route.

## Where the two differ

- **What drives the tree.** In RIBs, business logic decides which scopes exist, and a URL is an input a workflow
  translates. In fespalier, the location is the source of truth and state flows in through guards. That is what makes
  web URLs, the back button, deep links and typed routes work with no routing code of their own. In exchange, state with no URL
  lives in a provider, not in the tree.
- **One codebase, not two.** RIBs' README lists first a shared architecture across iOS and Android, for a Swift app
  and a Kotlin app. A Flutter app is one codebase, so that part of the problem is already solved.
- **Ceremony.** A RIB is up to six classes: router, interactor, builder, presenter, view and component. A fespalier
  feature is a folder of small files with no fespalier base class or interface to implement: plain functions and
  widgets.
- **Streams.** RIBs passes data through Rx streams and listeners. fespalier uses Riverpod providers, and a `data.dart`
  may return a `Stream`.
- **Isolation.** RIBs isolates a feature by its DI scope: a child sees only what its parent's component exposes, and
  the compiler checks it. fespalier has no such boundary: a Riverpod provider can be read from any file. A feature's
  files sit in its folder (`_components/` never routes), a package gives a hard boundary when one is needed, and a
  deferred route keeps a page's code out of the web build's main file until it is opened
  ([Deferred routes](navigation.md#deferred-routes-a-pages-code-on-demand)).

## Moving a feature over

1. **Give each screen a URL.** Each RIB with a view becomes a folder with a `page.dart` at the path it should have.
   Each viewless RIB becomes a `(group)` folder with no `page.dart` that holds what it did for its children: a guard,
   a layout, section data.
2. **Split the interactor.** What it loads goes to `data.dart`, what it writes to `action.dart`, and what it did in
   `didBecomeActive` and `willResignActive` to `observe.dart`'s `onEnter` and `onLeave` for a RIB with a view. A
   hook runs for each page, so a viewless RIB's setup goes to its section `data.dart` or a provider instead, with its
   teardown in `ref.onDispose`.
3. **Turn routing decisions into guards.** A router that attached one child or another from the interactor's state is
   a `guard.dart` that watches that state and returns the other location.
4. **Turn components into providers.** Dependencies become providers, overridden in `startup()` for the app and in
   tests for fakes.
5. **Turn workflows into URLs.** A deep link is the location of its last screen, with guards in front. Notification
   and shortcut taps go through `fespalier_push` and `fespalier_launch`.
6. **Move the tests.** An interactor test becomes a test of the route's data and action providers in a
   `ProviderContainer` with overrides. `fsp test` adds a smoke test that opens every route.

If the app being moved is already a go_router app, [Migration](migration.md#adopting-fespalier-in-a-go_router-app)
shows how to mount fespalier's tree inside it and move one folder at a time.
