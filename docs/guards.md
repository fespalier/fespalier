# Guards

```dart
// lib/app/(members)/guard.dart: guards /inbox, /admin and everything else in the group
GuardResult guard(Ref ref, {required Uri uri}) =>
    ref.watch(session) ? null : LoginRoute(from: uri.toString()).location;
```

`guard.dart` exports `GuardResult guard(Ref ref, {…})`. It returns a location to redirect to, or `null` to let the navigation through, and may be async. It guards every route at and below its folder; the folder needs no `page.dart`, so put one in a `(group)` or at the root to cover a whole section. A `guard.dart` with no `page.dart` or `redirect.dart` at or below its folder is a warning.

**It runs again when what it watches changes** (since 0.5.0). `ref.watch` a provider in the guard and, when that provider changes and the answer is now different, the router runs the redirects again. Signing out moves you to the login page from whatever member page you were on, a pushed page too (since 0.21.0, see [A guard on a pushed page](#a-guard-on-a-pushed-page)), with no refresh code of your own.

- Nothing is wired up: it works for `AppRoutes.router()` and for a router of your own built from `AppRoutes.mount()`, with no `refreshListenable`.
- The login page is not under that guard, so signing in is the login page's to navigate (`returnTo`), unless it has a guard of its own that watches the session.
- `ref.read` is for what must be the current value when you navigate; it never changes the answer later. A guard that returns the same answer after a change does nothing.
- An async guard watches the same way, through a provider's `.future`:

  ```dart
  Future<String?> guard(Ref ref, {required Uri uri}) async =>
      await ref.watch(currentUser.future) == null
          ? LoginRoute(from: uri.toString()).location
          : null;
  ```

**Rules and behaviour.**

- **What it costs.** Return synchronously when you can: a guard that needs no `await` should not be `async` (nor return `Future.value(...)`). It then answers in the same frame as the navigation, and the first frame at boot (a cold deep link too) already shows the page. Any `Future`, even a completed one, costs the router a frame, and the first frame is blank. Each navigation runs the guard in a fresh `autoDispose` provider, so what it `ref.watch`es is shared with the rest of the app and fetched once. The guard runs again after a change and again when the router asks, so keep it cheap (a guard signing out runs twice; the data providers it watches are not fetched twice).
- **When it stops watching.** The guard of the location the router shows keeps watching. It is dropped when a navigation ends on a location that does not run it, and when the router or the app goes. A guard that redirected is kept until the next navigation commits. A guard on a pushed page reacts while the page is on top (since 0.21.0): when its answer changes, the router asks again, and the answer decides where the page goes. If the page at the bottom of the stack is under a redirect (its own, a parent's or a shell's), the router is asked with `refresh()`: when the redirect there moves that page, it replaces the whole stack (a sign-out over a pushed `/orders/1` on `/orders` ends at the sign-in page with nothing of `/orders` under it, as before 0.21.0), and when the page keeps its place, the pushed page runs its guard again after that and moves alone, with the stack below it kept. When nothing under the pushed page is under a redirect, the page runs its guard again at once and moves alone. The guards of a base page under a pushed page, guarded or not, are not watched while it is covered (as before 0.21.0), and nothing runs them again by itself when it is uncovered, only a navigation that goes through the router's redirects. `GoRouter.pop` and `context.pop` of a page with no `leave.dart` are one, because go_router restores the page below with its redirect. The app bar's back button, `Navigator.pop`, the system back and the pop of a page with a `leave.dart` are not, so a base page below keeps the answer it had until the next navigation. A guarded pushed page is not like that: its guard is closed while another page covers it, and runs again when it is uncovered, however it was uncovered, also while the re-run of the page above it was still waiting ([A guard on a pushed page](#a-guard-on-a-pushed-page)). Don't call `ref.keepAlive()` in a guard: it keeps one provider alive per navigation.
- **A dirty page can be asked twice over a guarded base page (since 0.21.0).** When the guard of a pushed page changes and the page at the bottom of the stack is under a redirect, the router is refreshed first, and go_router restores a pushed page with a new entry, which asks its `leave()`; then the page's own guard runs again and moves it, which asks again. A change that only the pushed page's guard notices (a role revoked while the session holds) asks a dirty page twice if you let it go, and once if you refuse the first question (the refusal keeps the page, and the re-run does not follow). A guard that passes again moves nothing, and still asks once, for the refresh. A change the base page's redirect answers (a sign-out) replaces the whole stack and asks once, as before 0.21.0, and over a base page under no redirect the change is the re-run alone and asks once (nothing when the guard passes).
- **If it throws.** A guard that throws never moves the router: on a navigation its failure ends in the error view ([When a guard fails](#when-a-guard-fails)), and an error on a later run keeps the page you are on until the next navigation. The guard's provider does not retry.
- **Dialogs and sheets over a pushed page.** A guard that runs again on a pushed page (since 0.21.0) and passes leaves the page where it is, with its state, and a dialog or a sheet open over it stays. One that redirects, or fails so that the error view shows, replaces the page in the same place, and the dialogs, sheets and other routes without a page over it are closed first, so nothing of the old page stays on screen over the new one (the router keeps them otherwise, since the page keeps its key). What is closed is what the Navigator would close if the page were removed: the routes without a page over it on its own navigator, which for a page in a tab is the tab's. A dialog the app opened on the root navigator (`showDialog`'s default, `useRootNavigator: true`) from a page in a tab is over the tab layout and not over the pushed page, so it stays, as it does when a base page of the tab moves; open it with `useRootNavigator: false` to have it closed with the page. A page pushed on the root navigator (`parentNavigatorKey`) closes the dialogs on the root.
- **`ProviderContainer`.** A guard may still take `ProviderContainer c` first (`c.read(session)`): it is read once per navigation and never runs again by itself. Taking a `WidgetRef` is an error ("a guard runs outside the widget tree: take `Ref`").
- **Order.** Guards run outermost first, and the first one to return a location wins. A folder with a page and its own guard keeps it for that page and everything nested in it; guards above run first. A route with [`nest = false`](routing.md#a-sibling-with-a-compound-path) is not nested in the page above it, and still gets that page's guard, after the ones above it.
- **Parameters.** The `Ref` comes first, then named parameters:
  - `uri`: the requested location, a `Uri`.
  - `extra`: see [Typed `extra`](navigation.md#typed-extra).
  - The segments of the guard's own folder and the ones above it (`{required String shop}`), typed like everywhere else. A guard above `$id` can't ask for `id`: that's an error at the parameter.
  - Query parameters, optional and nullable (`String? ref`). They stay the guard's own and don't become fields of the typed routes below it (unless the guard sits next to a `page.dart`, where they are the page's).

**What gets generated.** Each page's `GoRoute` gets a `redirect` that calls, in order, the guards of the page-less folders above it and then its own (`refGuard(context, 'g8@3', (ref) => _i8.guard(ref, uri: state.uri))`, the string naming the guard on that route; since 0.7.0 each call sits in a `traceGuard` that returns it unchanged, for the [DevTools extension](devtools.md)). Since 0.21.0 each `redirect` runs its calls through `runRedirect`, which hands go_router a guard's failure as a `GuardFailure` (see [When a guard fails](#when-a-guard-fails)). Nested pages go through their parent's `redirect`, so no guard runs twice, and a route with `nest = false` carries its parent page's guard itself. There is no redirect on `ShellRoute` or `StatefulShellRoute`: go_router runs a matched route's redirect for deep links and for navigation inside a shell, tabs included.

When a path has a segment that doesn't parse (`/products/abc`), not-found is shown, and a guard that asks for segments or query parameters is skipped, since it has nothing to read. A guard that asks for neither (only `uri`, `extra`, or nothing) still runs, so it can redirect `/products/abc` to login.

## `redirect.dart`

A folder can hold `redirect.dart` instead of `page.dart`. It exports `String redirect({…})` (or `Future<String>`) returning the location to go to, and the route only redirects: no widget, no builder.

```dart
// lib/app/old-products/$id/redirect.dart: /old-products/3 → /products/3
String redirect({required int id}) => ProductRoute(id: id).location;

// ...or, reading a provider (a redirect's `ref.watch` runs once, it does not re-run)
String redirect(Ref ref, {required int id}) =>
    ref.read(catalog).contains(id) ? ProductRoute(id: id).location : const HomeRoute().location;
```

It takes the same parameters as a guard, except that the first one is optional: put `Ref ref` first if you need providers (since 0.5.0; `ProviderContainer c` also works).

- It runs once per navigation and does not watch: a redirect route never stays on screen, so there is nothing to run again.
- Segments are typed like anywhere else, so `/old-products/abc` shows not-found.
- It gets a typed route, named after its path (`OldProductsIdRoute(id: 3)`), so links to the old URL stay typed; query parameters it asks for are its fields.
- It takes part in route order and unreachable checks like a page, inherits the guards above it, and can sit next to a `guard.dart`, which runs first.
- A folder has a `page.dart` or a `redirect.dart`, not both, and a tab layout's own folder can't hold a `redirect.dart`. Routes in subfolders sit beside a redirect route rather than inside it, since anything inside would redirect too.

## When a guard fails

A guard or `redirect.dart` that throws, or whose `Future` completes with an error, fails the navigation it was run for. Since 0.21.0 that is the same on every go_router fespalier allows (`>=17.2.3 <19.0.0`): the generated `redirect` runs its calls through `runRedirect`, so go_router receives a `GuardFailure` in place of the error. A `GuardFailure` has two fields, `error` (what the guard threw, or what its `Future` failed with) and `stackTrace` (where it was thrown). Its message is `a guard or redirect.dart failed with <type>`, where `<type>` is the runtime type of `error`; go_router's own message for the same failure was `Exception during route redirect: …`.

What the router shows then depends on the route:

- **The route's error view, when it has one.** The route's nearest `error.dart` is the view of a failed guard when it takes nothing but `error`, `stackTrace` and `retry`, in any order, with the types an error view gets (`Object`, `StackTrace`, `VoidCallback`), and anything else optional. The router shows it at the address that was asked for, without the layouts above it, so it is the whole page. `error` is the failure, `stackTrace` its stack, and `retry` runs the navigation again (see [Retrying a pushed navigation](#retrying-a-pushed-navigation)); it does nothing once the router has moved on to another location. An `error.dart` that needs a segment or a query parameter is not this view: it is only the view of a failed `data.dart`, where the route has one, and it adds nothing to the typed route.
- **The not-found view, otherwise.** A route with no such `error.dart` shows the app's not-found view for the location, as a location that matches no route does (see [not-found views](routing.md#not-found-views)).

**The view brings its own `Scaffold`.** go_router builds its error route as a bare page: there is no `Scaffold` or `Material` around the view, and fespalier adds no layout, so an `error.dart` that is shown for a failed guard builds its own `Scaffold`. Without one, its text is drawn in Flutter's fallback style (large, red and underlined). Say something a person can act on, and keep the exception for the report: the `shop` example's `error.dart` shows "Something went wrong." and **Try again**.

The failure is reported once, in every build mode, with `FlutterError.reportError`: the library is `fespalier`, the context is `while running a guard or redirect.dart`, and the exception and stack are the guard's own. It goes to `FlutterError.onError`, which is where `SentryFlutter.init` listens, so a failure is not lost in a release build. A widget test therefore fails unless it calls `tester.takeException()`, as it already does for a failed `startup()`. With `FespalierSentry` (`telemetry: true`) next to `SentryFlutter.init`, a guard that fails after an `await` is still one event. The sink's, tagged with the route and the file, comes first. The report carries the same error object, and Sentry's deduplication (on by default, `enableDeduplication`) drops its event; with deduplication off it is two. A guard that throws before it returns reaches only the report, and the navigation's outcome `error`, which the "Did a failing check stop a screen from opening?" tile on the Errors dashboard counts ([Dashboards on your computer](telemetry-dashboards.md)).

The navigation ends. After `go`, a link or a tab, the page it was on is left: its `onLeave` runs, as it does for any page a navigation takes away. After a `push` the page stays under the error view, covered and not left; `pushReplacement` and `replace` over other pages removed the page they replaced before the guard ran, so that page is left. With `telemetry: true` the navigation ends with the outcome `error` (not `not_found`), and the commit reads `#n commit error`. The guard's own span carries the exception, so a failure is counted once in the "How many operations failed?" tile, and the "How often does a link lead nowhere?" tile does not count it. A guard that throws before it returns has no DevTools record and no guard span, since the failure never reaches `traceGuard`; the navigation's outcome and the error view are still there.

Any other error of go_router's (no route matched, a redirect loop, too many redirects) is still the not-found view and the outcome `not_found`. A guard that runs again because something it watches changed, and fails then, keeps the page you are on: there is no navigation to end and no report to take, and the next navigation runs the guard again.

A router you build yourself is covered when it passes the generated error route: `GoRouter(errorBuilder: AppRoutes.errorPage, ...)` (what `AppRoutes.router()` passes). go_router takes only one of `onException`, `errorPageBuilder` and `errorBuilder`, so a router with `onException` instead of `errorBuilder` shows nothing of fespalier's: its handler gets the same `GuardFailure` as `state.error`, and reporting it and showing something are its own. Tests of a failing guard call `tester.takeException()` for the report. After `go`, a link or a tab, they assert on the router's error: `router.routerDelegate.currentConfiguration.error` is a `GuardFailure`. After a `push`, that error is `null` (see below): assert on the error view.

### Retrying a pushed navigation

After `go`, a link, a tab or the first location, the failure is the router's own error, and `retry` calls `GoRouter.refresh`, which runs the navigation again. After `push`, and after `pushReplacement` and `replace` over other pages, go_router keeps the failed navigation in an entry on top of the stack, with the page it started from below, and the router's own `error` stays `null`. Since 0.21.0 the error view shows there too, the failure is reported, and `retry` replaces that entry with the same location and `extra`, keeping its page key: the guard runs, and a page that passes shows in its place, with the stack below it as it was. A retry that fails again shows the error view again, with a new report.

- **The `Future` of the `push` that failed** completes with `null` when the person goes back from the error view. `retry` keeps the failed entry's page key and replaces its page (since 0.21.0), so the `Future` of the failed navigation completes with the result of the page in its place when that page pops, as the `Future` of a push that succeeds does.
- **`pushReplacement` and `replace`** removed the page they replaced before the guard ran, so the failed entry sits on what was below that page, and the retry replaces the entry there; a `replace` kept the replaced page's key, and a `pushReplacement` made a new one, which the retry keeps.
- **A dialog, a sheet or another route without a page over the error view** is closed first when `retry` runs from it (since 0.21.0), so the retry replaces the error view and not the dialog: going back from the page it pushes leads to the page below, not to the error view.
- **A retry held after the router moved on** does nothing: the entry was closed, or another page was pushed above it (a page, not a dialog: its own dialogs and sheets stay open).
- **Telemetry** ends the navigation with the outcome `error` as above, and its location is the one that failed. Nothing is entered for the failed location. The page under the error view is covered: after a `push` it is not left, after `pushReplacement` or `replace` the page they replaced left (its `onLeave` runs, as it does when the navigation succeeds), and it gets its `onFocus` (and a page focus event) when the error view closes, not before.

## A guard on a pushed page

A guard on a page you reach with `push`, `pushReplacement` or `replace` works like the guard of a page you reach with `go` (since 0.21.0; before, only the navigation that opened the page ran it). Two things make that so:

- **It watches while the page is on top.** When what it watches changes and the answer is different, the router asks again and the answer decides where the page goes (see "When it stops watching" above). A sign-out moves a pushed page to the sign-in page, as it moves any other.
- **It runs again when go_router shows the page without it.** go_router restores a pushed page without running its redirect on a `refresh()`, a restore (the browser's back and forward, a platform link), a pop back to it, a tab coming back and a hot-reload swap (flutter/flutter#133985; its failed case is fespalier/fespalier#258). fespalier runs the guard of such a page again after the frame, as a `replace` of the page with its own location, a **re-run** in this page. The page keeps its key, so a guard that passes again leaves the page in place with its state.

The commit is judged once, whichever reader of it sees it first (DevTools in a debug build, telemetry, the page gate, the guards' own listener). fespalier tells a page from another by go_router's own objects, the entry's `completer` and the `RouteInformationState` of the navigation that put it there, and listens to the router's delegate and to nothing else: no listener on the route information provider, no timer, no microtask, no zone of its own. Only post-frame callbacks. What shows meanwhile depends on whether the page has passed its guard before:

- **A page whose guard has never passed is held back.** The entry of a push that failed, once a refresh has restored it, and a page restored on a cold start, show an empty box where the page would be, and the page is never built, entered or asked `leave()`, until the guard has run again and its answer shows: the page when it passes, the error view when it fails, the redirect when it redirects. The navigation commits as the outcome `error` with no route, and ends at the location of the held page; DevTools reads `held: its guard runs again`.
- **A page that passed before stays visible until its guard answers.** It is not held: one frame for a synchronous guard, the whole wait for an asynchronous one.
- **An asynchronous guard.** The re-run waits and the page stays on screen, so the person can leave it meanwhile: the back button of an app bar, `Navigator.pop`, `GoRouter.pop` or the system back. That question is asked as it is with no re-run (a dirty page asks, and a refusal keeps it). When the guard answers, the page is either gone or still there. **If it is gone** (a pop, a `go`, another page pushed over it, a refresh that gave it a new entry), nothing comes back and the late answer changes nothing. **If it is still there**, the answers received so far are replayed by position in a new re-run that lands in its own call: no guard runs a second time, no `Future` is waited for, and the landing has every answer when `leave()` is asked.
- **What `leave()` is asked at the landing.** A re-run whose guards pass again asks nothing and the page stays. One that redirects, or fails so that the error view shows, moves the page and asks `leave()` as a base page's redirect does, whatever the destination (the exemption of a [flow section](navigation.md#leaving-a-page-leavedart) is for a navigation the app made, not for this). This is true also after the person refused a question about the page while the guard waited: that was a question about their pop, and the guard's move is asked on its own at the landing (a clean page goes, a dirty one asks again, and a refusal keeps it). A landing that passes is refused while a question about the page is still open, so the person's answer still finds the page it was asked about.
- **A re-run that a `leave()` refused.** The refusal keeps the page and its guard: when the guard passes again nothing is asked and the page stays (over a guarded base page the refresh that change asks for asks once, as above), when it refuses again that is a new move and is asked once more, and a pop back to the page while it still refuses asks again.
- **The `Future` of the `push`** completes with what the page in its place pops with (`null` if that has another type, with a debug report), also after a refresh gave the entry a new completer.
- **A guard that sent the page elsewhere stops watching it.** A push whose guard redirected, and a re-run that moved the page, leave the page key showing another route. The guards that answered a location are closed when that commit lands, so a change back does not navigate the page that replaced it again; the guards of the location it moved to stay. The same holds when the app's own `replace` puts another route on a pushed page, which keeps its page key: the guards of the route that stood there are closed when the replace lands, except those the new route evaluates again, so a change of an old guard does not run the new page again.
- **A guard that does not watch anything** (a `ProviderContainer` guard, a `redirect.dart`) runs on each of these, where it ran once at the push.

A `replace` or a `pushReplacement` that takes the place of the base page leaves no pushed page (go_router gives a plain list), and its guards are the base's, watched as after a `go`.

### What go_router still skips, and the limits of a re-run

Not fixed by fespalier, because go_router decides it:

- a pushed page **with no guard** is restored as go_router restores it, and its `Future` does not complete after a refresh (flutter/flutter#128122);
- the system back to a guarded **base** page does not run its guard;
- in a debug build, a hot reload while a base guard's failure is on screen shows that page.

The limits of the re-run itself:

1. **A page that passed before stays visible until its re-run lands**: one frame for a synchronous guard on a restore, the whole wait for an asynchronous one. A base page behaves this way too.
2. **The replay is by position, within one synchronous turn.** A top-level `redirect` of your own that answered differently within that turn would put an answer at the wrong place. A generated router has no top-level `redirect`.
3. **With an asynchronous `onEnter` (an adapter's) or an asynchronous top-level `redirect`, no redirect runs inside the re-run's call.** The re-run is then neither dropped nor carried on: its landing is asked without the flow section's and the query-only exemptions, a passing one asks a dirty page, and a way back during its wait can bring the page back. With a synchronous `onEnter`, app code that pops the page in the microtask gap before the landing gets the landing's verdict.
4. **A move that a `leave()` refused keeps the page while its guard refuses**, as it does on a base page. A move that arrives while the person's own question is open shares that question.
5. **Over a guarded base page, a change that only the pushed page's guard sees can ask a dirty page twice** (see above).
6. **A guard evaluated after another guard's `await`, once the router has reported over the request, is bound to the base.** Its change then refreshes the router, which is safe: the base's redirect decides and the pushed page runs its guard again after that.
7. **A redirect that does not go through `runRedirect`** (a hand-written `GoRoute` redirect) is not seen: the page it guards is held for one frame and run once, and a re-run it moves is taken for one that passes.
8. **A guard or a listener that navigates synchronously inside a re-run's call is not supported.**
9. **A `refresh()` while an asynchronous re-run waits** is parsed by go_router with whatever the route information provider holds then, which depends on which reader of the commit registered the Router's report first (DevTools and telemetry listen before the Router widget). The end state is the same, the number of questions a dirty page is asked can differ by one.
10. **A dropped re-run's `replace` `Future` never completes.** The carried one forwards its result to the `push` that opened the page.

**UNCHECKED on a device.** The tests run the held page, the re-run and the closing of the dialogs in Flutter's test binding, and no test sees a screen. These are claims about a device that need a run on one, and none is stated as fact here:

- how a held page looks: an empty box, then the re-run's result;
- whether the in-place `replace`, which keeps the page key, animates well;
- a cold start or a web reload with a pushed guarded page on top;
- a held deferred page (its library loads, and its page shows after the re-run);
- a held page inside a tab shell;
- the back button of an app bar pressed while an asynchronous guard waits: what the person sees between the press, the question and the landing;
- Android's predictive back during an asynchronous guard's wait: what the gesture previews, and what it does when the question is refused or the guard answers in the middle of it;
- a re-run that moves the page while the app is in the background (paused or hidden): the question is asked as soon as the guard answers, with no frame. The tests pin it with a binding whose frames are off, and whether a device shows the question while hidden is not known;
- the dialogs, sheets and other routes that a moving re-run closes, on a device;
- the browser's address bar and history after the `replace` of a re-run that moves a page: no test runs the browser's history.

## Sending people back

```dart
LoginRoute(from: uri.toString()).location   // /login?from=%2Finbox%3Ffolder%3Dsent
```

A guard that redirects to a login page can pass along where the user was going. Ask for `Uri uri` (the requested location, query included) and put it in the login route's query, as above. `login/page.dart` takes it as a query parameter (`this.from`, a `String?`), and when the user is done it calls `returnTo`:

```dart
context.go(returnTo(from));                  // from if it's a location in the app, else '/'
```

`returnTo(from, fallback: '/home')` only lets an absolute path through: `https://…`, `//host` and the like fall back, so a crafted `?from=` can't send people off your app. Both `uri` and the typed routes include the mount prefix when the tree is mounted with `at:`.

## Feature flags: fespalier_flags

Since 0.9.0. A feature flag is a value the app asks for by name and that a server, a vendor SDK or a build can change: show `/labs` to some users, move `checkout` to its second version. `package:fespalier_flags` gives guards a source of values. A flag is a provider that answers **at once** (never an `AsyncValue`, never a `Future`), so a guard that watches one stays synchronous, and a menu entry behind it follows the flag because [menus run guards](layouts.md#menus-and-breadcrumbs-navdart). It adds no dependency beyond fespalier, no timer and no polling.

Add it next to fespalier, with the same `url` and the same `ref` ([Companion packages](getting-started.md#companion-packages) says why):

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.20.0
  fespalier_flags:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_flags
      ref: v0.20.0
```

<!-- x-release-please-end -->

Declare each flag once, `const`, gate a route with `flagGuard` in its `guard.dart`, and read a flag anywhere that has a `Ref` or a `WidgetRef`:

```dart
// lib/flags.dart
const labs = BoolFlag('labs');
const checkoutV2 = BoolFlag('checkout_v2');
const pageSize = IntFlag('page_size', fallback: 20);

// lib/app/labs/guard.dart: /labs is there while the flag is on
GuardResult guard(Ref ref) => flagGuard(ref, labs, orElse: const HomeRoute().location);

// a widget, a provider, a guard: the value is there at once
final size = ref.watch(flag(pageSize));
```

`BoolFlag` is off unless the source says otherwise (its `fallback` is `false`); `StringFlag`, `IntFlag` and `DoubleFlag` have a required `fallback`. A flag is its **fallback** whenever the source has no value for its key, has one of another type, throws, or has not started yet, so a flag is never loading. Two declarations with the same type, key and fallback are the same flag.

A `nav.dart` beside the `guard.dart` needs nothing else: while the flag is off the guard refuses the entry, and a refused entry is hidden (`NavRefused.hide`, the default; `whenRefused: NavRefused.disable` greys it out instead).

**Patterns.**

- **A new route behind a flag:** `lib/app/checkout-v2/guard.dart` is `flagGuard(ref, checkoutV2, orElse: const CartRoute().location)`. A whole section: the guard goes in a `(group)` or in the section's folder, as any guard.
- **The old URL goes to the new one while the flag is on:** `checkout/guard.dart` is `flagGuard(ref, checkoutV2, whenOff: true, orElse: const CheckoutV2Route().location)`.
- **The same URL, two pages:** no guard; the page switches: `ref.watch(flag(checkoutV2)) ? const CheckoutV2() : const CheckoutV1()`.
- **A flag and a sign-in:** a folder has one `guard.dart`, so compose with `??`. `flagGuard` returns a `String?`, synchronously: `flagGuard(ref, labs, orElse: '/') ?? (ref.watch(session) ? null : LoginRoute(from: uri.toString()).location)` (with [`fespalier_auth`](auth.md): `?? requireSignedIn(ref, uri, signIn: ...)`).
- **A flow that must not be pulled from under the user** (a checkout): `flagGuard(ref, checkoutV2, orElse: '/', follow: false)` reads the flag once per navigation (`ref.read`): the page stays open when the flag turns off, the next navigation applies it, and a menu does not follow.

**Live updates.** A source can send an event when values change (`FlagSource.changes`: `FlagsChanged({'labs'})` names the keys, `FlagsChanged.all()` means any). `fespalier_flags` listens with **one subscription per `ProviderContainer`**, opened when the first flag is watched and cancelled when the last watched flag goes, and reads again only the watched flags the event names. A guard, a menu or a widget runs again only when the value it reads **differs**, so a flag that turns off on `/labs` takes the app to `orElse` in the next frame (a pushed `/labs` too, since 0.21.0) and a menu entry under it hides, with no navigation. Nothing in the package polls or starts a timer; a vendor's own streaming or polling runs inside its SDK, by its settings.

**What to know.**

- **A guard that redirected stays subscribed until the next navigation**, so a flag's subscription can outlive the page it gated by one navigation: a cold deep link to `/labs` with the flag off lands on `/`, and the flag is still listened to until the user goes somewhere else.
- **A guarded page under a pushed page that has no guard** does not react until it is uncovered (the rule of every guard).
- **A cold deep link before the source is ready** sees the fallback, so a guard sends it to `orElse`: await the vendor's local load in `startup()` (below).
- **Never call a vendor's async API in a guard.** PostHog's `isFeatureEnabled` is a `Future`: the guard answers a `Future`, the menu entry turns pending and the first frame is blank. Copy the value into a [`FlagSource`](#where-flag-values-come-from) and read that.
- **`follow: true` (the default) takes a user off a page** when the flag turns off mid-flow, if it was reached with `go`, a link or a tab. A pushed page goes too (since 0.21.0: the guard of a pushed page watches while the page is on top, [A guard on a pushed page](#a-guard-on-a-pushed-page)). Use `follow: false` for a flow.
- **Each change re-reads the watched flags the event names.** Vendors that count evaluations (LaunchDarkly) or track exposures (GrowthBook) see those reads; a keyed `FlagsChanged` keeps them to the keys that changed.

**Not built.** A `route.dart` constant (`const flag = 'checkout_v2'`), vendor **packages** (each bridge is 15 to 40 lines of mapping, so they are recipes, below), and a DevTools panel for flag values.

### Where flag values come from

`startup()` returns the source, once: `flagSource.overrideWithValue(source)`. Without one, `flagSource` is `const ConstFlags()`: every flag is its fallback.

```dart
// lib/app/startup.dart
Future<List<Override>> startup() async => [
  flagSource.overrideWithValue(const ConstFlags({'labs': bool.fromEnvironment('LABS')})),
];
```

A `FlagSource` is four synchronous typed reads (`boolValue(key, fallback)`, `stringValue`, `intValue`, `doubleValue`) and `Stream<FlagsChanged>? get changes`. Every read must answer **from memory**: guards and menus call it, so never from the network, a file or a platform channel. A read that throws is the flag's fallback (printed in debug).

| Source               | What it is                                                                                                                                      |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `ConstFlags({...})`  | Fixed values, or `--dart-define`d ones. `changes` is `null`. A bool reads a `bool`, a double any `num`; a value of another type is the fallback |
| `AsyncFlags(future)` | A source that is not ready at start: reads come from `meanwhile` until the future completes, then one `FlagsChanged.all()`                      |
| A vendor bridge      | Your own `FlagSource` over the vendor's SDK: a recipe, below                                                                                    |
| `FakeFlags({...})`   | For tests: [Testing flagged routes](#testing-flagged-routes)                                                                                    |

**Initial values, with no timer.** `startup()` awaits only what is **local**: Remote Config's `ensureInitialized()` and `activate()` (the values the previous session fetched), LaunchDarkly's construction, PostHog's `setup()` and a read of the app's keys from the native SDK's cache. From the first frame every read is a synchronous call into the vendor's memory.

- A vendor whose start waits for the network (GrowthBook past its cache's TTL, LaunchDarkly's `start()` on a first launch, which "may not complete until ... the device leaves airplane mode") goes in `AsyncFlags(start(), meanwhile: ...)`: the fallbacks (or the app's last known values) until the `Future` completes, then one `FlagsChanged.all()`.
- An app that must see remote values before its first frame awaits the vendor in `startup()` with a `.timeout()` of its own if it wants one: that timer is the app's choice, and tests never reach it (they override `flagSource`).

**Recipes.** Firebase Remote Config, LaunchDarkly, PostHog and GrowthBook have a recipe, about 15 to 40 lines each (a class that `implements FlagSource` and a `startup()` that returns it), in [`skills/fespalier-guards/references/flag-sources.md`](https://github.com/fespalier/fespalier/blob/main/skills/fespalier-guards/references/flag-sources.md). They are not packages because no fespalier logic is left in them. **OpenFeature** is the common interface to converge on, but its Dart SDK is a beta, so it is not adopted; `FlagSource` mirrors its typed reads and its configuration-changed event, and a bridge is about 25 lines.

### Testing flagged routes

`FakeFlags` (in `package:fespalier_flags/testing.dart`) is a `FlagSource` that holds values in memory. Give it to `pumpRouter` as an override, or to the setup file of `fsp test`:

```dart
testWidgets('labs is there with the flag on, and goes with it', (tester) async {
  final flags = FakeFlags({'labs': true});
  await pumpRouter(
    tester,
    AppRoutes.router(initialLocation: '/labs'),
    overrides: [flagSource.overrideWithValue(flags)],
  );
  expect(currentLocation(tester), '/labs');

  flags.set('labs', false);   // delivered synchronously
  await tester.pump();        // one frame: the guard ran again, the router moved
  expect(currentLocation(tester), '/');
});
```

```dart
// test/routes/setup.dart: `fsp test` tests a flagged route instead of skipping it
List<Override> overrides(String pattern) => [
  flagSource.overrideWithValue(FakeFlags({'labs': pattern == '/labs'})),
];
```

- **`set(key, value)`** sends `FlagsChanged({key})` before it returns, `setAll({...})` one event for several keys, and a `null` value removes the key. Call them from the test body, not while a widget builds.
- **`FakeFlags.strict({...})`** throws a `StateError` for a key it lacks or a value of another type, and reports it to `FlutterError.reportError`, so a typo in a key fails a `testWidgets` instead of reading the fallback.
- **`listenerCount`** is how many listen to its changes: `0` once nothing watches a flag.
- Without an override, every flag is its fallback, so existing tests of an app that adds a flag see the flag off.

## Biometric unlock: fespalier_biometrics

Since 0.13.0. A route behind a fingerprint or a face (an orders list, a wallet, a secret) is a guard with one rule that is easy to break: **a guard never prompts.** A guard runs again whenever something it watches changes, on every navigation and on a cold deep link, so a guard that showed the platform's sheet would show it again each time. `package:fespalier_biometrics` splits the job in three: a state (`biometricUnlock`: `Locked`, `Unlocking`, `Unlocked(at)`), a guard (`requireUnlocked`) that reads the state and redirects to the app's unlock page, and one function that prompts, `unlock()`, which the unlock page or an action calls and which is single-flight. It depends on fespalier and `package:clock`, starts no timer and adds no listener.

Add it next to fespalier, with the same `url` and the same `ref` ([Companion packages](getting-started.md#companion-packages) says why):

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.20.0
  fespalier_biometrics:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_biometrics
      ref: v0.20.0
```

<!-- x-release-please-end -->

The platform check is **not** in the package. `local_auth` 2.x and 3.x cannot share one source (2.x takes `AuthenticationOptions` and defaults `useErrorDialogs` to native dialogs, 3.x takes named parameters, throws `LocalAuthException` and needs Flutter 3.38 or newer), so the package defines a `BiometricPrompt` (`isAvailable()` and `authenticate(reason)`, returning a `BiometricOutcome`: `success`, `cancelled`, `failed`, `unavailable`, `lockedOut`) and each `local_auth` is a recipe of about 25 lines in the fespalier-guards skill (`biometric-prompts.md` for 3.x, `biometric-prompts-local-auth-2.md` for 2.x). It shows the platform's own sheet and never a Flutter dialog. The app gives its prompt in `startup()`:

```dart
// lib/app/startup.dart
Future<List<Override>> startup() async => [
  biometricPrompt.overrideWithValue(const LocalAuthPrompt()), // your BiometricPrompt
];
```

Until it does, reading `biometricPrompt` throws a `StateError` that names the override.

### The unlock page

```dart
// lib/app/vault/guard.dart: guards /vault and everything below it
GuardResult guard(Ref ref, {required Uri uri}) =>
    requireUnlocked(ref, uri, unlock: (from) => UnlockRoute(from: from));
```

`requireUnlocked` returns `null` while the app is unlocked and the unlock page's location (with `from`, the `uri` it was going to) otherwise. It is synchronous, so a cold deep link shows the unlock page in its first frame. The unlock page sits **beside** the guarded folder (a guard on it would redirect to itself), asks, and goes back:

```dart
// lib/app/unlock/page.dart
FilledButton(
  onPressed: () async {
    final outcome = await ref.read(biometricUnlock.notifier).unlock('Unlock your vault');
    if (outcome == BiometricOutcome.success && context.mounted) context.go(returnTo(from));
  },
  child: const Text('Unlock'),
)
```

Since 0.19.0 that button is also ready-made: [A ready-made unlock page](#a-ready-made-unlock-page).

- **`unlock(reason)` is single-flight and never throws.** While a sheet is up, a second call (a double tap, two buttons) gets the same `Future`. A prompt that throws is `BiometricOutcome.failed`. Anything but a success leaves the state as it was before the call.
- **The guard watches only whether the app is unlocked.** A prompt coming and going (`Unlocking`) and a second `Unlocked` stamp do not run it again, so a re-run is never a re-prompt; a `lock()` or a relock does run it, and the router leaves the page, a pushed page too (since 0.21.0, [A guard on a pushed page](#a-guard-on-a-pushed-page)). A prompt over an unlocked page (an action's) does not send the page away: `Unlocking` carries whether the app was unlocked, and the guard keeps its answer.
- **`maxAge:`** also requires the unlock to be younger than that by `package:clock`. It is evaluated when the guard runs or when `isFresh(maxAge:)` is asked, that is at the next navigation (or any re-run of the guard), never by itself: there is no timer, so a page left open stays open.
- **`biometricAvailable`** is a `FutureProvider<bool>` for the unlock page, which can offer "Use your passcode" instead of a button that cannot work. It asks the prompt once: one that throws is an `AsyncError`, and since 0.16.0 nothing retries it (Riverpod's default re-asked the plugin up to ten times over about 50 seconds, with a `Timer`); `ref.invalidate(biometricAvailable)` asks again.

### A ready-made unlock page

Since 0.19.0, `package:fespalier_biometrics/material.dart` has `BiometricLockScreen`, the body of the unlock page above with the button, the words and the "cannot ask" case written once. It is the only library of the package that imports Material, a library-boundary rule as in `fespalier_adaptive`: `fespalier_biometrics.dart` and `lib/src/` import none, so an app that draws its own page builds on a model with no widget set in it.

```dart
// lib/app/unlock/page.dart
BiometricLockScreen(
  reason: 'Unlock your vault', // what the platform's sheet says
  onUnlocked: () => context.go(returnTo(from)),
  title: const Text('Vault'), // optional
  unavailable: (context) => const Text('Use your passcode'), // optional: shown instead of the button
  messages: const BiometricLockScreenMessages(unlock: 'Deverrouiller'), // optional: another language
)
```

- **It prompts when the button is tapped and never otherwise.** Not in `build`, because a rebuild is never a prompt, and not after the first frame either: the package schedules no frame and starts no timer. A double tap is one sheet (`unlock()` is single-flight) and one `onUnlocked`.
- **The button is disabled while a sheet is up.** A `failed` try shows `messages.failed` ("Not recognised. Try again."), a `lockedOut` one `messages.lockedOut`, and a `cancelled` one nothing, because the person chose it; the button stays for another try.
- **`unavailable`** replaces the button when `biometricAvailable` answers `false`, or when a tap ends `unavailable`; without a builder it shows `messages.unavailable` as a `Text`. While the answer is still pending, or if the plugin threw, the button stays and a tap reports what happened.
- **It opens no dialog, route, menu, sheet or snack bar.** The platform's own sheet is the prompt.
- **Rejected on purpose: a `BiometricGate` that overlays the whole app when it is locked.** It would be a second way to say "locked" beside the guard, and a subtree parked under an overlay keeps its state, and so its secrets, in memory.

**To ask as soon as the page opens**, use the unlock folder's own [`observe.dart`](observability.md#route-lifecycle-observedart) `onEnter`, which fespalier runs after the frame and never in `build`. It sits in the same `lib/app/unlock/` folder as the page the guard redirects to, and it **replaces** the tap-only page above: the hook prompts on every entry, so a redirect to the unlock page asks. A hook has no `BuildContext`, so the page leaves when the app is unlocked, whoever asked:

```dart
// lib/app/unlock/observe.dart
void onEnter(Ref ref) {
  if (ref.read(biometricUnlock) is Locked) {
    ref.read(biometricUnlock.notifier).unlock('Unlock your vault');
  }
}
```

```dart
// lib/app/unlock/page.dart
class UnlockPage extends ConsumerWidget {
  const UnlockPage({super.key, this.from});

  final String? from;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(biometricUnlock, (_, next) {
      if (next is Unlocked) context.go(returnTo(from));
    });
    return const BiometricLockScreen(reason: 'Unlock your vault', onUnlocked: _stay);
  }
}

void _stay() {} // the listener above leaves the page
```

- **The screen shows the outcome of a prompt it started.** A prompt the hook started that ends `failed`, `lockedOut` or `unavailable` shows no message and does not switch to the `unavailable` builder; the button is the way to try again, and a tap during the hook's sheet joins it (`unlock()` is single-flight), so it is still one sheet.
- **Built already unlocked** (a URL visit), the screen shows the button and a tap prompts again (`Unlocking(wasUnlocked: true)`); the hook above skips an unlocked app.
- **After a relock** the guard sends the person to the unlock page and the hook prompts right then; whether iOS accepts a prompt at that moment is unchecked, like the cold start.

Unchecked on a device: an `onEnter` prompt on a cold start and right after a relock on resume (iOS may refuse a prompt while the app is not yet active), the grace with the sheet hiding the app, and VoiceOver and TalkBack on the screen.

### Actions that ask again

```dart
// lib/app/vault/reveal/action.dart
Future<String> action(Ref ref, {required String input}) =>
    withBiometrics(ref, 'Show the card number', () => loadCardNumber(ref));
```

`withBiometrics(ref, reason, action, {maxAge})` is for the write or the read that must not run on a borrowed phone. It prompts unless the unlock is younger than `maxAge` (the default, `Duration.zero`, asks every time), runs `action` after a success, and throws `BiometricDeclined(outcome)` otherwise, which an [action](actions.md)'s state shows like any failure. A success also counts as an unlock for the guards.

### Relock when the app comes back

`BiometricUnlock` watches core's `appShowSignal` (since 0.13.0: `AppLifecycleListener.onShow`, the app is visible again **after it was hidden**), so a return from the background runs its `build` again, and it goes back to `Locked` when that return is at least `BiometricPolicy.resumeGrace` after the unlock. The guard then sends the person to the unlock page. It adds no listener of its own and no timer (`appShowSignal` is core's one `AppLifecycleListener`, kept alive while the notifier is). It is not `appResumeSignal`: an iOS notification shade or Control Center, a call banner and the platform's own biometric sheet make the app inactive and back, and none of them is a return from the background.

```dart
// lib/app/startup.dart: every return from the background locks
biometricPolicy.overrideWithValue(const BiometricPolicy(resumeGrace: Duration.zero)),
```

**The default grace is 10 seconds, and that is a trade-off.** The platform's sheet and some system overlays can hide the app and show it just after the sheet's answer, so with `Duration.zero` the sheet could undo its own unlock. The price is a window of 10 seconds after each unlock in which putting the app in the background and bringing it back asks nothing: on a borrowed phone, that is the time someone has. An app that guards something worth more sets a shorter grace, or zero, and checks on a device that the platform's sheet does not lock it. Switching apps through the iOS app switcher without the app being hidden is not a return either. A return while a sheet is up never drops the prompt, and one past the grace still relocks when the sheet ends without a success (`persistAcrossBackgrounding`). A clock set back counts as expired, so winding the clock back does not keep an unlock. Locking does not clear the data providers that loaded a secret; invalidate them when `biometricUnlock` goes to `Locked` if that matters.

Each prompt is reported as one `fespalier.biometrics.prompt` operation with `fespalier.biometrics.result` set to the outcome's name, to an installed [telemetry](observability.md#telemetry) sink. Never the reason text.

### Idle lock

Since 0.19.0 an app can lock itself after a stretch without a touch, so a phone left unlocked on a table does not keep the vault on screen. It is off by default (`idleTimeout` is null), and the package still starts no timer: **the app fires a ticker, and the package measures time**.

```dart
// lib/app/startup.dart: lock after two minutes without a touch or a hardware key
biometricPolicy.overrideWithValue(const BiometricPolicy(idleTimeout: Duration(minutes: 2))),
```

Three things do the work, and each reads `clock.now()`:

- **Activity.** Put `BiometricActivity` in `MaterialApp.router(builder: (context, child) => BiometricActivity(child: child!))`. Every pointer down, pointer signal (a mouse wheel), trackpad pan or zoom start and hardware key event that reaches it calls `BiometricUnlock.touch()`, which writes a field and not state, so a touch rebuilds nothing. Key events are seen only when a widget below holds the focus, and they are never handled here. **Typing on a soft keyboard is not activity**: it reaches Flutter through `TextInput`, not as key events, so a long message typed for `idleTimeout` would be locked on the next tick. A text field that people type in for a while tells the unlock:

  ```dart
  TextField(onChanged: (_) => ref.read(biometricUnlock.notifier).touch())
  ```

  The idle age counts from the later of the unlock and the last touch; a clock set back counts as idle, like the grace.

- **The ticker.** `biometricIdleTicker` is a signal that never fires by itself, the shape of `fespalier_cratestack`'s `syncTicker`. The app fires it from its own `Timer.periodic`, `ref.read(biometricIdleTicker.notifier).fire()`, at most `idleTimeout / 4` apart and **stopped while the app is hidden**; on a tick `BiometricUnlock` goes to `Locked` when the unlock has been idle for `idleTimeout`, and the guard sends the person to the unlock page. The period, the pause and the test (`fire()`) are the app's, which is why core and this package stay timer-free. The lock waits for the first tick after the limit, so any setup locks up to one period late; a period of at most `idleTimeout / 4` bounds that. The fespalier-guards skill has the ticker as a compiled recipe.
- **The first touch after the limit.** When the limit has already passed, `BiometricActivity` **absorbs** the next touch: it is hit-tested to a box above the page and not to the page, so the button under the finger is not pressed, and it locks. While the unlock is idle, mouse hover effects and cursors on the page drop out until the next click, and the first touch is absorbed on a page that no guard covers too (it locks; the page stays where it is). This is time-based, so it is right even when the ticker is late or the app has none (the idle lock then locks on the first touch). Pointer routes are fixed when a touch is hit-tested, so locking from a pointer-down callback alone would let that touch through.

`requireUnlocked` and `isFresh` also treat an unlock that has been idle for `idleTimeout` as locked, so the next navigation lands on the unlock page with no tick at all. `isIdle()` answers the same question for your own code. A touch that comes after the limit never brings the unlock back, and a tick during a prompt keeps the prompt; a lock that was due applies when the prompt ends without a success.

Use a positive `idleTimeout`; `BiometricUnlock` asserts it in debug builds.

Unchecked on a device: the app's periodic timer while the app is hidden, the first touch absorbed on a real screen, and a hardware keyboard.

### Secrets behind the biometric

Since 0.19.0 a value the person must unlock to read (a card number, a recovery phrase, a token) can be kept behind the biometric. **The gate is the keystore's**, not Dart's: a value merely hidden behind `unlock()` is plain data in memory or on disk, readable by any code that skips the guard. An item written with the OS's access control cannot be decrypted without the check: iOS asks as part of the keychain read, and Android's key is created to require the person's presence. So the package depends on no plugin: you write a `BiometricSecrets` once (the `flutter_secure_storage` recipe in the fespalier-guards skill is about 60 lines), and `biometricSecrets.overrideWithValue(...)` in `startup()` gives it to the app. Unconfigured, reading `biometricSecrets` throws a `StateError` that says so.

```dart
// in an event handler (never in build or a guard)
final secret = await ref.read(biometricUnlock.notifier).readSecret('card', 'Show the card number');
switch (secret) {
  case SecretFound(:final value):
    showCard(value);
  case SecretMissing():
    askForTheCardAgain();
  case SecretRefused(:final outcome):
    showWhy(outcome);
}
```

- `readSecret(key, reason)` answers `SecretFound(value)`, `SecretMissing()` (nothing stored, or the keystore made the item unreadable, such as an iOS item bound to `biometryCurrentSet` after a new finger was enrolled) or `SecretRefused(outcome)` with the same `BiometricOutcome` as a prompt. It never throws for a refusal, and a store that throws is `SecretRefused(failed)`. `writeSecret(key, value, reason)` answers a `BiometricOutcome`, and `deleteSecret(key)` removes one (it needs no sheet). A store that fails makes `deleteSecret`'s `Future` fail (the secret may still be there): a failed delete at sign-out must not be silent. `SecretFound.toString()` hides the value.
- **One sheet at a time.** A read that comes while `unlock()`'s sheet is up waits for it (and the other way round), two reads of one key share one `Future` and one sheet, and reads of two keys are two sheets in order. No timer is involved: the package keeps a line of `Future`s. An `unlock()` that queues behind a read's sheet is `Unlocking` from the call, so a lock screen's button is disabled for the whole read sheet. **A store must always answer**: one that never does blocks every later `unlock()` and secret operation until the app restarts, because the package may not time it out.
- **A read does not unlock the app.** The state stays `Locked` (or whatever it was) and tells no listener: Android's `biometricOrDeviceCredential` accepts a PIN, and a read is consent to one value, not proof that the owner is holding the phone. Unlock first (`unlock()`) when the page needs it.
- **The value goes to the caller only.** No provider holds it, and telemetry never sees it. `lock()` leaves stored secrets alone, so delete an account's secrets at sign-out.

Each operation is one `fespalier.biometrics.secret` operation with `fespalier.biometrics.secret_op` (`read`, `write` or `delete`) and `fespalier.biometrics.result` (`found`, `missing`, `success`, `cancelled`, `failed`, `lockedOut` or `unavailable`) to an installed [telemetry](observability.md#telemetry) sink: constants only, never the key, the value, the reason or the store's error (its text can name the key). A store that threw ends as `error` without the error object.

In tests, `FakeBiometricSecrets` (a stored map, an outcomes queue, `reads`, `writes` and `deletes` counts, `hold()` and `release()`) goes in with `biometricTestOverrides(prompt, secrets: fake)`.

Unchecked on a device: Face ID, Touch ID and fingerprint reads, cancel and lockout, a newly enrolled finger with `biometryCurrentSet`, and Android `strongBiometricOnly` against `biometricOrDeviceCredential`.

### Testing an unlock

`package:fespalier_biometrics/testing.dart` has `FakeBiometricPrompt` (outcomes from a queue, a `prompts` count, `reasons`, `hold()` and `release()` for a sheet that is up) and `biometricTestOverrides(prompt, policy:)`, the overrides for `pumpRouter` or a `ProviderContainer`:

```dart
testWidgets('locked: the vault sends the person to unlock, and nothing is prompted', (tester) async {
  final prompt = FakeBiometricPrompt();
  await pumpRouter(
    tester,
    AppRoutes.router(initialLocation: '/vault'),
    overrides: biometricTestOverrides(prompt),
  );
  expect(currentLocation(tester), startsWith('/unlock'));
  expect(prompt.prompts, 0);

  await tester.tap(find.text('Unlock'));
  await tester.pumpAndSettle();
  expect(currentLocation(tester), '/vault');
  expect(prompt.prompts, 1);
});
```

Move time with `withClock(Clock.fixed(...))` for `maxAge` and the grace, and fire a return from the background with `container.read(appShowSignal.notifier).fire()` (the real signal needs a `WidgetsBinding`, which `biometricTestOverrides` swaps for a plain one; with a binding, `handleAppLifecycleStateChanged` through `hidden` and back is the real thing).
