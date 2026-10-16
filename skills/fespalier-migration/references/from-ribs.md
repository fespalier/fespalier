# Coming from RIBs

As of v0.18.0. For an app or a team that knows Uber's [RIBs](https://github.com/uber/RIBs) (Router, Interactor,
Builder; iOS and Android). The user documentation is `docs/coming-from-ribs.md`; this page is what an agent needs to
translate a RIB, or a RIBs habit, into fespalier files.

**fespalier has no RIB type and is not a RIBs port.** Never generate `Router`, `Interactor`, `Builder` or `Component`
classes in a fespalier app: each part becomes a file kind under `lib/app/` (plain functions and widgets) or a Riverpod
provider. The one inversion to keep in mind: in RIBs business logic decides which scopes are attached; in fespalier
the **location** decides what is on screen, and state reaches the tree through guards that redirect.

## The mapping

| A RIBs part or habit                                            | Write in fespalier                                                                                                                                              |
| --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A RIB with a view                                               | A folder with a `page.dart` at the URL the screen should have                                                                                                   |
| A viewless RIB (`LoggedIn` in the tutorial)                     | A `(group)` folder (no URL segment) with a `guard.dart`, a `layout.dart` or a section `data.dart`                                                               |
| Router: attach one child or another from the interactor's state | `guard.dart`: `ref.watch` the state, return the other location or `null`; it runs again when the watched state changes                                          |
| Interactor: loading                                             | `data.dart`                                                                                                                                                     |
| Interactor: writes                                              | `action.dart` (`XRoute.submit`, with pending and error state)                                                                                                   |
| Interactor: `didBecomeActive` / `willResignActive` side effects | `observe.dart` `onEnter` / `onLeave` (and `onFocus`)                                                                                                            |
| Builder                                                         | Nothing: `fsp` reads the constructors and writes `lib/app.g.dart`                                                                                               |
| Component (dependencies)                                        | Riverpod providers; app overrides from `startup()`; test overrides                                                                                              |
| Presenter                                                       | Usually nothing: the page takes typed data; reshape in `data.dart` or a provider                                                                                |
| Parent to child: `build()` argument or Rx stream                | Segments and query parameters (typed constructor parameters), section data, providers                                                                           |
| Child to parent: a listener                                     | An action, a provider the parent watches, or a typed navigation                                                                                                 |
| Workflow / ActionableItem (a deep link in steps)                | The location of the last screen; guards gate it; `from` plus `returnTo(from)` after sign-in; `fespalier_push` and `fespalier_launch` for taps                   |
| A scope that outlives one screen (a trip in progress)           | Section data (`data.dart` beside a `layout.dart` in a folder with no `page.dart`), or a keep-alive provider for state with no folder                            |
| State per screen instance                                       | `fespalier_riverpod` (`pageProvider`, `pageNotifierProvider`, since 0.13.0)                                                                                     |
| A multi-step flow on one screen (one RIB per step)              | A `Notifier` in that page; separate routes only if each step should have a URL                                                                                  |
| Interactor unit tests                                           | A `ProviderContainer` with overrides (`container.read(XRoute.action(1).notifier).call(input)`), `pumpRouter` for widget tests, `fsp test` for route smoke tests |
| Xcode templates, the IntelliJ RIB plugin                        | `fsp new '<path>' --data --action --guard …`                                                                                                                    |

## The tutorial app, as folders

RIBs' tutorial: `Root` attaches `LoggedOut`; after sign-in it attaches the viewless `LoggedIn`, which switches
between `OffGame` and `TicTacToe`. In fespalier:

```text
lib/app/
  login/page.dart            LoggedOut (takes `String? from`)
  (signed-in)/               LoggedIn: a group, nothing added to the URLs
    guard.dart               ref.watch(session) ? null : LoginRoute(from: uri.toString()).location
    layout.dart              what the signed-in screens share
    page.dart                → /       OffGame
    game/page.dart           → /game   TicTacToe
```

Signing out needs no code (the guard runs again); the login page finishes with `context.go(returnTo(from))`; with
`fespalier_auth` the guard is `requireSignedIn(ref, uri, signIn: (from) => LoginRoute(from: from))`. The rules for
guards, `returnTo` and the session are in [`fespalier-guards`](../../fespalier-guards/).

## Traps for someone used to RIBs

- **A state with no URL is not a folder.** Don't invent routes for scopes the user cannot link to; use section data
  or a provider. Do give a URL to every screen a user can reach with back, a link or a reload.
- **Don't navigate from a provider or an `observe.dart` hook to switch scopes.** Switching scopes on a state change
  is a guard's job: it watches the state, and the router redirects.
- **Don't keep business state in a widget's `State` to mimic an interactor.** A `data.dart`, an `action.dart` or a
  provider is the scope; the page is the view.
