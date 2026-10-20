# Migration

## Adopting fespalier in a go_router app

You do not have to move everything at once: fespalier can mount its generated routes inside the `GoRouter` you already have, so you can bring one section of the app over at a time.

1. Install `fsp` and add the package ([Installation and setup](getting-started.md)).
2. Keep the default `main: auto` and put the router in `lib/app/app.dart`: a `GoRouter router()` that returns your own `GoRouter` with `...AppRoutes.mount(at: ...)` among its routes (step 4). The generated `main()` calls it once, so `startup.dart`'s `ready()` and `attach()` (since 0.12.0) still run around it ([`main()`](app-startup.md)). Set `main: manual` only if you want to keep your own `main()` as it is: `fsp` then writes no `main()` and reads neither `app.dart` nor `startup.dart`, so you call `ready` and `attach` yourself. [`examples/adopt`](../examples/adopt) is the worked case, including a 0.11-style `main()` moved into `ready()` and `attach()`.
3. Put the first routes under `lib/app/` and run `fsp gen` (or keep `fsp watch` running).
4. Mount the generated routes in your router. `at` is the URL prefix:

```dart
GoRouter(
  navigatorKey: rootKey,
  routes: [...yourRoutes, ...AppRoutes.mount(at: '/x', navigatorKey: rootKey)],
)
```

Under `main: auto`, that `GoRouter(...)` is what `router()` in `lib/app/app.dart` returns. [`examples/adopt`](../examples/adopt) shows it, with `ready()` and `attach()` in `startup.dart` in place of a hand-written `main()`.

Pass `mount` your `GoRouter`'s own `navigatorKey`: routes that render on the
[root navigator](navigation.md#the-root-navigator-navigatordart) name it as their `parentNavigatorKey`,
which go_router requires to be an ancestor navigator's. (`AppRoutes.router()` takes a `navigatorKey:`
too, and either way the key is `AppRoutes.rootNavigatorKey`.)

## Upgrading

What changed between releases, newest first, each with a link to the reference section that describes the behavior today. There is no 0.8.0 release: it was tagged but never published, and the wave it carried ships as 0.8.1.

### 0.21.0

0.21.0 breaks nothing, and `app.g.dart` is unchanged for an app that spells each type the same wherever it is compared (a page and its `data.dart`, a guard and its page). Where a parameter's type is written as a `typedef` or with an import prefix instead of as the type itself, the app regenerates a different `app.g.dart` (the three bullets after the first). Three more changes touch what an app sees without touching its code: the telemetry stack moves to OpenObserve v1.1.2 (the first bullet), `fespalier_frb` rebuilds less, so a test that counted reloads after a burst may count fewer (the fifth), and two packages raise a lower bound, of dio and of crypto (the last bullet).

- **The telemetry stack moves to OpenObserve v1.1.2, which migrates its data** ([Dashboards on your computer](telemetry-dashboards.md)). `fsp telemetry` pins v1.1.2 where it pinned v1.0.4, and OpenObserve migrates the stack's database on its first start; v1.0.4 cannot open it afterwards. The stack in `~/.fespalier/telemetry` is shared by every app on the computer, so use `fsp` 0.21.0 or later for `fsp telemetry` in all of them: an older one writes the v1.0.4 file back, and OpenObserve restarts in a loop (`Migration file of version '…' is missing` in its log, and the importer says it did not answer). Run the newer `fsp telemetry` again: OpenObserve starts on the same data, and `--reset` is not needed. It also makes a Grafana percentage tile say 100 % when every call in the range failed, where it said _Not enough data yet_. No app code changes.
- **A typedef of a query type is a query parameter.** An _optional_ parameter of a page or layout whose type is a `typedef`, declared in the app's own files, of a query type (`String?`, `int?`, `double?`, `bool?`, a `List` of them, or an enum) is now a query parameter, where it was left to its default, so its typed route gains that optional argument. The one exception is a type that the route's `data.dart` yields spelled the same (`Future<Tags>` and `final Tags tags;` with `typedef Tags = List<String>;`): that is the data, as it was. [Known limitations](troubleshooting.md#known-limitations) says which types are followed.
- **A typedef or an import prefix of a data type gets the data.** A page or layout parameter spelled with a `typedef` or an import prefix (`m.Product`) of what a `data.dart` yields now gets the data by type, where an optional one was left to its default. The exact spelling is tried first, so a parameter that spells the data's type as the `data.dart` does is bound as before.
- **A typedef of a type that is filled by type is filled too.** A parameter whose type is a `typedef` of one of the types the generator fills by type is bound like that type: an _optional_ `Kid footer` with `typedef Kid = Widget;` in a layout gets the page, as an optional `Widget footer` always did, next to the layout's `child`, so the page is built twice. The same goes for `typedef Failure = Object;` in an error view (the error) and `typedef Retry = void Function();` (the retry).
- **`fespalier_frb` rebuilds less** ([A rebuild budget](data.md#a-rebuild-budget-changebudget)). A topic's key is rebuilt only by an event that concerns it, and a burst goes through in one event-loop turn while some watched key is not concerned or something watches `changes.latest`; before, Riverpod took a burst one event per turn whenever nothing else watched `changes.latest`, so a key could reload once per event of it. A test that counted reloads after a burst may count fewer now (a key watched alone reloads as before); no code changes. A topic's value counts the events that concerned the key, so one rebuild can move it by more than one (a listener on `topic(42)` that saw `[1]` for the burst `[42, 7, 42]` sees `[2]` while something watches `changes.latest`): compare rebuilds, not the number. An exception that a matcher throws reaches a direct listener of the topic (`container.listen(topic(key), ..., onError: ...)`) as a `ProviderException`, where it arrived as the matcher's own exception. `ChangeBudget`, a budget of one move per key per tick of a provider you fire, is new and opt-in.
- **`fespalier_auth` asks for dio 5.7.0 and `fespalier_storage` for crypto 3.0.6** (they asked for dio 5.4.0 and crypto 3.0.0). An app that lets pub choose changes nothing; one that holds a lower version in `dependency_overrides:` or `pubspec.lock` runs `flutter pub upgrade dio crypto`. Why: the repository now spells each third-party dependency one way in every pubspec, and these were the two packages that allowed less than their siblings (`fespalier_dio` and `fespalier_cratestack` already asked for dio 5.7.0, and every other package that uses crypto for 3.0.6).

### 0.20.0

0.20.0 breaks nothing: an app with a `data.dart`, an `action.dart`, a deferred page or a type written with an import prefix in a route file regenerates `app.g.dart` (below), with no code change; any other app's is unchanged.

- **The generated names follow the folders** ([Which edits swap](cli.md#a-hot-reload-after-a-regeneration)). The providers, the deferred libraries, the optimistic layers and the actions are named after their folder, not after where the route sorts: `_dataProductsId`, `_libCheckout`, `_optimisticTeamsTeamId`, `_actionNotesId_edit`. So are the DevTools sites, `dProductsId` and `aNotesId_edit`; the guard and `redirect.dart` sites (`g5@6`, `r32`) do not change, and neither does a route's class. A prefixed type's import alias (`_e…_m`) is made from the library the prefix imports, not from the file that spells the type. The names are private and the DevTools extension reads any site, so no code changes; run `fsp gen` and commit the result, since `fsp check` fails on a stale file until you do ([Failing CI on a stale file](getting-started.md#failing-ci-on-a-stale-file)). A hot reload now swaps a route added or removed anywhere, so `fsp dev` reloads it instead of restarting. Still refused: a changed `data()` or action, a moved folder that has one (and the second of two folders whose names share a stem, added or removed, when one has a `data.dart` or an `action.dart`; two deferred pages alone swap), an import prefix pointed at another library (it was accepted before 0.20.0), and a router setting. A script that reads `fsp routes --graph json` finds the new site ids.

- **A deferred route added or removed hot reloads too** ([Which edits swap](cli.md#a-hot-reload-after-a-regeneration)). `AppRoutes.deferred` is a getter now, where it was a `static final` list, and a deferred page's import is named after its folder (`deferred as _pageCheckout`, where it was `_i7`). So an app with a deferred route regenerates `app.g.dart`, with no code change: code that reads `AppRoutes.deferred` or calls `loadDeferred()` works as before. Now a swap: a deferred route added, removed or moved beside another; a page added with `deferred: true`; `deferred` turned on or off. `fsp size` reads the new names, so run `flutter build web` again first; an older build reports that it was built from another `lib/app.g.dart` ([Web chunk sizes](cli.md#web-chunk-sizes-fsp-size)). Before 0.20.0, adding a route before a deferred one was refused (it changed `AppRoutes.deferred`), but a file that is not a route (a `loading.dart`, an `error.dart` or a `guard.dart` in the root, or in a folder that sorts before a deferred route) renumbered the position-based import (`_i2` became `_i3`) while every hash the reload compares stayed the same. That swap went through, and the deferred page then threw "Deferred library ... was not loaded" until a restart: a bug of 0.19.0 that 0.20.0 fixes, since the import keeps its folder's name.

### 0.19.0

0.19.0 breaks nothing for an app whose telemetry sinks extend `FespalierTelemetry` (every sink fespalier ships does): every app regenerates `app.g.dart` (below), and an app that does not name its screen or set `otel: true` changes nothing else. A telemetry sink that implements `FespalierTelemetry` instead of extending it adds one method (below). With `fespalier_sentry`, the scope is named at the commit, which changes a few events from a page's first frame (below).

- **Optional: native crash records can name the screen** ([The screen a native crash happened on](observability.md#the-screen-a-native-crash-happened-on)). Bump `otel_zone` to `64c4661ac6cd09718141864d528892916677cc38` (v0.8.1, on the rc.4 line; v0.7.0 was the first with `onScreen`) in your pubspec, pass `onScreen: observability.setCrashScreen` to `FespalierOtel`, and run `fsp telemetry --stop`, then `fsp telemetry`, so the collector reads the new attribute and the Errors table has its panel. `app.g.dart` is not changed by this item (every app regenerates it for 0.19.0, below). An app that does none of this keeps its crash records as they are.
- **A telemetry sink of your own** ([Several sinks](observability.md#several-sinks-combine-and-add)). `FespalierTelemetry` has a new member, `commit(navigation, commit)`, with an empty default: the router tells it what each navigation commits, before the page is built. A sink that extends `FespalierTelemetry` changes nothing; one that implements it stops compiling until it adds the method (or extends instead), and one with a member already named `commit` of another signature renames it. `RecordingTelemetry` writes commit lines only with `recordCommits: true`.
- **Optional: OpenTelemetry without wiring** ([OpenTelemetry from the generated main()](observability.md#opentelemetry-from-the-generated-main)). Add `otel: true` under `fespalier:`, next to `telemetry: true`, and delete the hand wiring: in `lib/main.dart`, `Future<void> main() => AppMain.run();`, and in `lib/app/startup.dart` the `OtelZone`, its `start()`, the `FespalierOtel` sink, the two observers and any `zone()` that runs `runGuarded`. `fsp gen` warns while the `OtelZone` or the `FespalierTelemetry.install` is still in startup.dart. A sink that `startup()` still installs with `FespalierTelemetry.install` must use `FespalierTelemetry.add`, once (guarded by `FespalierTelemetry.contains`, because Retry runs `startup()` again), or it replaces the OpenTelemetry sink. `fespalier_otel` resolves with `otel_zone` v0.8.0 or later, but only v0.8.1, the pin above, runs the generated zone on the web: on v0.8.0 the app works on mobile and its web build is blank, so use the pin. An app with `main: manual` keeps its own `main()`, and `otel: true` is refused there. For this item only `lib/app.main.g.dart` changes; `app.g.dart` changes for 0.19.0 in every app (below).
- **Sentry names a page at its commit** ([What Sentry gets from fespalier](observability.md#what-sentry-gets-from-fespalier)). The scope's transaction name, `fespalier.route` and, next to `fespalier_otel`, `otel.trace_id`/`otel.span_id` are set when a navigation commits, before the new page's `initState` and first `build`. Most events read the same: Sentry's own capture of an exception reads the scope after the frame, and a guard, `data()` or action error takes its `fespalier.route` from its call site. What changes is what reads the scope during that frame: an event captured on a copy of it (`captureException(..., withScope: ...)` in your code, and fespalier's own events, whose transaction name now is the page being opened), and code that reads `scope.transaction` or the tags, such as a page's `initState`. From the commit until the first frame, an event from the page being left names the destination too (`captureException` right after `router.go(...)` in the same handler). A search on the transaction name finds these events under the page being opened. Nothing to change in code; a test that read `sentry.tags` or `transactionName` before a pump now sees the new page.
- **Every app regenerates `lib/app.g.dart`**: run `fsp gen` and commit the result (a committed file that is not regenerated is stale: see [Failing CI on a stale file](getting-started.md#failing-ci-on-a-stale-file)). There is no code change. `AppRoutes.router()` builds a `GoRouter.routingConfig` over a routing config, the same router in release; the layouts' navigators and shells take their keys from `AppRoutes`, so a hot reload keeps the pages in them; and `AppManifest.byType` and `AppManifest.byPath` are getters over the same maps. A hot reload in a debug build now swaps in the regenerated route table, with limits: a route added, removed or moved swaps when no route after it in the order of `fsp routes` has a `data()` function, an action or a deferred page (the generated names of those are numbered by position, and a changed name is refused), and a provider, a deferred library or a router setting that changed is refused too. A refused swap prints one message and keeps the old routes until a hot restart; stable names made from the folders will lift the limit on position in a later release. `fsp dev` now hot reloads after a regeneration that swaps, and hot restarts after one that does not ([the CLI reference](cli.md#a-hot-reload-after-a-regeneration)).

### 0.18.0

0.18.0 breaks nothing: the generated `app.g.dart` is unchanged unless an app lists the new `fespalier_launch` adapter, an app that does not use telemetry changes nothing, and `fespalier_frb`'s `ChangeCodec` is new and opt-in.

- **Four attributes on the data and action spans**: `fespalier.data.attempt` (which try a load is), `fespalier.data.source` (`cache` or `fetch` for a `dataCache`), `fespalier.action.rolled_back` (an optimistic patch was taken back) and `fespalier.action.invalid` (the run ended with `FieldErrors`). They come with `telemetry: true`, like the others; the names are in [Telemetry conventions](telemetry-conventions.md#telemetry-conventions). A `RecordingTelemetry` log gains the `attempt=`, `source=`, `rolled_back=` and `invalid` tokens, so a test that compares whole lines needs them.
- **The Screens and Actions tiles for them need the stack restarted once**: run `fsp telemetry --stop`, then `fsp telemetry`, which rewrites the files and updates the dashboards, so the collector reads its four new dimensions ([Dashboards on your computer](telemetry-dashboards.md)). An app before 0.18.0 sends none of the four, so those tiles read 0.
- **`fespalier_launch` is new and opt-in** ([Shortcuts and widgets](launch.md)). It opens a typed route from a home-screen shortcut or a widget tap, cold or while the app runs. An app that does not list it regenerates an identical `app.g.dart`, and nothing else changes. An app that lists it gets one more adapter in `AppAdapters`, calls `FespalierLaunch.configure(sources:, route:)` in `main()` before `AppMain.run()`, and configures it in every widget test that boots `AppMain.root()` (`FespalierLaunch.debugReset()` in `setUp` and `tearDown`, as for fespalier_push). The plugins (quick_actions, home_widget) stay the app's: the recipes are in the `fespalier-routing` skill.
- **`fespalier_frb` decodes raw core messages: `ChangeCodec`** ([Decoding a core's events](data.md#decoding-a-cores-events-changecodec)). Nothing changes for a feed over typed events, and `ChangeFeed` is unchanged. If your `open` decodes raw messages itself (`rawChanges().map(decode)`), a message that failed to decode was an `AsyncError` in `latest`; with `.transform(ChangeCodec(decode))` it is skipped and counted, `latest` keeps its last change, and a decoder can throw `UnknownChange` for a variant a newer core added.

### 0.17.0

0.17.0 is about code generators, where fespalier and freezed or `build_runner` trip over each other, and it changes
nothing for an app that does not use them (the generated `app.g.dart` is unchanged, and nothing breaks):

- **`ExtraCodec.of` finds an `extra` with `is`, so a freezed class restores** ([Restoring `extra` on the web](navigation.md#restoring-extra-on-the-web)). Nothing is removed or renamed; this is for an app whose `extra` is a freezed class written as `const factory Note(...) = _Note`. The object is a private `_Note`, so `ExtraCodec({Note: ...})`, which looks a type up by its exact runtime type, never matched it: the extra was saved as `null` and a web reload gave the page `null`, without a word. Change `lib/app/extra_codec.dart`, and keep the old constructor for anything else:

  ```dart
  // Before (0.16.0 and earlier): never matches a freezed `Note`
  final extraCodec = ExtraCodec({
    Note: (toJson: (Note n) => n.toJson(), fromJson: Note.fromJson),
  });

  // After (0.17.0): the first ExtraType the object `is` takes it
  final extraCodec = ExtraCodec.of([
    ExtraType<Note>(toJson: (n) => n.toJson(), fromJson: Note.fromJson),
  ]);
  ```

  A debug build now also prints one line, once per type, for an `extra` that no entry takes (a release build prints nothing), so the next one you forget is not silent.

- **`fsp` warns when `build_runner` would delete `lib/app.g.dart`** ([The generator](cli.md#the-generator)). The builders that write `.g.dart` files (json_serializable, riverpod_generator) claim an `X.g.dart` for every `X.dart`, so an app with `build_runner` and a `lib/app.dart` loses fespalier's default output on the next `dart run build_runner build`, with nothing logged. `fsp gen`, `check`, `watch` and `dev` now warn on `lib/app.dart`, and still succeed; the generated code is unchanged. Set `output: lib/routes.g.dart` (then `fsp gen`, and change the `app.g.dart` imports), rename `lib/app.dart`, or keep `lib/app.dart` out of `source_gen:combining_builder` in `build.yaml`, which `fsp` reads and then stays quiet.
- **The examples no longer pass `-d` to `build_runner`.** It has ignored the flag since 2.7.0. The commented `tasks:` that `fsp init` and `fsp create` write, and the docs, leave it out; a `tasks:` you wrote with `-d` still works.

### 0.16.0

0.16.0 raises the floor to Flutter 3.35 and Dart 3.9, changes one member of `FespalierAdapter`, fixes the places where a
write could be sent twice, a provider started a hidden timer, a notification tap was lost and a step name did not compile,
makes three outcomes of the network packages right (one port, `DownloadBackend.resume`, gains a named parameter: see the
resume item), so an app sees different outcomes there, and adds opt-in tooling:

- **Flutter 3.35 and Dart 3.9 are the floor** ([Requirements](getting-started.md#requirements)). **Breaking, for an app on
  Flutter 3.32 to 3.34:** `fespalier` and every companion that was in the 3.32 floor job declare `sdk: ^3.9.0` and
  `flutter: ">=3.35.0"` (`fespalier_sign_keypair`, Flutter 3.44, and `fespalier_download_background`, Flutter 3.47, keep
  their own). On an older Flutter `flutter pub get` fails naming the SDK, and `fsp create` says
  `Flutter {v} is too old: fespalier needs Flutter 3.35 or newer`. Upgrade Flutter (3.35.7 is the last 3.35 patch, Dart
  3.9.2), set the same `flutter-version` in CI, and raise your own `environment:`; an app that has to stay on 3.32 to 3.34
  stays on 0.15.x. The floor does not change `lib/app.g.dart`.

  ```yaml
  environment:
    sdk: ^3.9.0
    flutter: ">=3.35.0"
  ```

- **go_router's lower bound is 17.2.3** (it was 17.0.0). An app that lets pub choose changes nothing: 17.2.3 is the newest
  go_router that Flutter 3.35 to 3.37 resolve. An app that holds go_router 17.0.0 to 17.2.2 in `dependency_overrides:` or
  `pubspec.lock` runs `flutter pub upgrade go_router`. Why: Flutter 3.32 resolved go_router 17.0.0 and no newer one (17.0.1
  asks for Flutter 3.35); that release ran a `Block.then` of an `onEnter` inside the parse, before the commit, and
  asserted on a platform payload with no leading slash. On 17.2.3 neither needs a workaround.
- `fsp create --features all` now includes `otel` on every supported Flutter, and an app it makes declares
  `sdk: ^3.9.0` and `flutter: ">=3.35.0"`.

The generated `app.g.dart` changes in an app with `adapters:` (regenerate: `AppAdapters.handlesEnter`, and the router
passes `onEnter` only when an adapter has one) and is unchanged in an app without. Adapters:

- **An adapter's `onEnter` is a getter** ([Adapters](adapters.md)). `FespalierAdapter.onEnter` was a method in
  0.11.0 to 0.15.0 and is now a nullable getter, `FespalierEnter? get onEnter => null;`, where `FespalierEnter` is the
  function type of the old method. `AppRoutes.router` passes go_router an `onEnter` only when some adapter's getter is
  not null (`onEnter: AppAdapters.handlesEnter ? onEnter : null`; before, any `adapters:` entry passed one), and only
  those adapters are asked. **An adapter that overrides the method no longer compiles**, which is the point: the
  analyzer says `Class 'MyAdapter' can't define method 'onEnter' and have field 'FespalierAdapter.onEnter' with the same name.`
  instead of the adapter being skipped without a word. No first-party adapter had an `onEnter`. Regenerate (`fsp gen`):
  `lib/app.g.dart` changes in an app with `adapters:`, and not in one without.

  ```dart
  // Before (0.15.0)
  @override
  FutureOr<OnEnterResult>? onEnter(InboundNavigation navigation) {
    if (navigation.next.uri.scheme != 'vaam') return null;
    return Block.then(() => navigation.router.go('/orders/42'));
  }

  // After (0.16.0)
  @override
  FespalierEnter? get onEnter => (navigation) {
    if (navigation.next.uri.scheme != 'vaam') return null;
    return Block.then(() => navigation.router.go('/orders/42'));
  };
  ```

- **`go()` then `push()` keeps both again, in an app whose adapters have no `onEnter`.** Any `onEnter` makes go_router
  parse every navigation asynchronously, so before 0.16.0 `router.go('/a'); router.push('/b');` ended as `/home > /b` and
  `currentConfiguration` lagged a frame in every app with `adapters:`; now it is `/a > /b`, committed in the call. An app
  with an adapter that has an `onEnter` still has the async parse.
- **A router of your own** passes `onEnter: AppAdapters.handlesEnter ? AppRoutes.onEnter : null` instead of
  `onEnter: AppRoutes.onEnter`.

The other fixes make a write that could be sent twice be sent once, so an app sees different outcomes in these places:

- **An upload after a `5xx`, `408` or `499` is `Failed(other)`, an unknown outcome** ([Uploads](downloads.md#uploads)).
  On 0.15.0 every HTTP error but 401 and 403 ended `Failed(rejected)`, and `Uploads.retry` sent an upload without an
  `Idempotency-Key` again after a `500` or `504`, which could run the write twice. Now only a client error that proves
  nothing was applied is `rejected`; the others are `other`, `outcomeUnknown(id)` is true for an upload without a
  key, and `retry` and `start` refuse it until you `remove` it on purpose. A download is unchanged.
- **An upload whose registry entry cannot be saved is `Failed(storage)` and is not sent.** `UploadStore.put` may throw
  (`UploadStoreException` from `FileUploadStore`), and `FileUploadStore` no longer reads an unreadable file as empty:
  `load` and `put` throw and leave the file alone, and an upload without a key is not started until the registry can be
  read (the next `open()`) or `clearAccount()` empties it. Handle `Failed(storage)` with `retry`.
- **A `5xx` without a CrateStack envelope keeps an intent's key** ([CrateStack with fespalier](cratestack.md)). A bare
  `500` is `CrateStackOffline`, not `CrateStackUnavailable`; only a `5xx` in the envelope moves to the next key. A read
  behind `serve` falls back to the saved copy on it. On 0.15.0 the next key could run a committed write twice.
- **`IntentQueue.drain` reads each intent again before it sends it,** so an intent that was accepted, discarded or wiped
  while the drain was busy is not sent from a stale list.
- **A request with a body is sent again after a 401 through `DioHttpClient`** ([HTTP clients](http.md)). An
  `http.Request` (`get`, `post`, `put`, `patch`, `delete`) goes to Dio as bytes, so `SessionInterceptor` refreshes and
  sends it again whole (`WriteGuard` lets that one second send of a write through, as it always did after a 401). Before
  0.16.0 it failed with `ClientException: fespalier_dio: unknown` and the refresh never helped: remove a retry you wrote
  around that. A streamed or multipart request is not sent again: the caller gets the 401 as the response, after the
  refresh. A `ClientException` from `DioHttpClient` that has no Dio message now carries its cause
  (`fespalier_dio: unknown: <cause>`): code that compared the whole message changes.
- **Offline while a token refreshes is `Failed(network)`, no longer `Failed(unauthorized)`** ([Credentials](downloads.md#credentials)).
  A download whose credentials could not be reached ends `network` when its grantor, or the `HttpCredentials` of
  `HttpDownloadBackend`, throws an `http.ClientException` (`fespalier_auth`'s `AuthUnavailable` is one). `unauthorized`
  stays for a refusal and for any other throw. If your app treats `unauthorized` as "sign the person in again", it no
  longer does that for being offline: show "offline, try again" for `network` and call `Downloads.retry`. A `resume` whose
  grantor cannot be reached leaves the download `Paused` and returns false.
- **A paused download resumes from its freshly granted address, and each resume gets its own renewal**
  ([Credentials](downloads.md#credentials)). Before 0.16.0 `resume` asked the grantor and threw the new `url` away, so an
  expired signed address earned a 403 first, and only one renewal existed for the whole life of the download: a second
  long pause ended `Failed(unauthorized)`. Now `resume` goes to the grant's `url` (the bytes kept stay), and a start, a
  retry and a resume each have one renewal. The grant a `resume` asks for is used now, not
  discarded. **A `DownloadBackend` of your own** (a fake in a test, a custom transfer) must accept the new `url:` named
  parameter of `resume(id, {authorization, url})`: `flutter analyze` names the override that is missing it.
  `FakeDownloadBackend.resumeUrls` records it.
- **An app with a `links:` section gets [`AppRoutes.urlOf`](cli.md#urls-to-share-approutesurlof)** when it regenerates,
  the absolute URL of a route on the first domain: a doc comment and one method after `matchUrl`. An app without
  `links:` regenerates byte for byte, and a first domain that is not usable is a warning of `fsp gen`, as before.
- **`fespalier: test: a11y:` is opt-in** ([Route smoke tests](route-tests.md#route-smoke-tests-fsp-test)). With `true`
  (or a list of `tap_targets`, `labels`, `contrast`) every test `fsp test` writes also checks Flutter's accessibility
  guidelines once its page is on screen; without it the file is the one it always was.
- **The DevTools extension has an _Adapters_ tab** ([DevTools extension](devtools.md#what-it-shows)), and the protocol is
  still 1: `hello` lists `adapters` in its features. A tool of your own that compares `features` exactly should ask
  `contains`.
- **A plugin that throws is not asked again** ([Biometric unlock](guards.md#biometric-unlock-fespalier_biometrics), [Push](push.md), [Offline-first](offline-first.md), [Change feeds](data.md)). `biometricAvailable`, `pushPermission`, `pendingIntents` and `ChangeFeed.latest` did not set `retry:`, so Riverpod 3's default re-asked a throwing plugin or store up to ten times over about 50 seconds, with a `Timer`. They now keep the error and ask once; `ref.invalidate(provider)` asks again.
- **A notification tap while the app starts is opened** ([Push](push.md#cold-start-and-taps)). It was lost (`launch()` runs before `runApp`, `attach` after the first frame, and nobody listened to `taps` in between). `launch()` now keeps the latest tap and `attach` opens it once; the cold-start notification seen again on `taps` is still opened once. A `PushSource.taps` on a platform channel must return one stream every time, because `taps` is listened to twice while the app starts.
- **`fsp check` refuses a step folder that is no Dart enum constant** ([Multi-page forms](forms.md)): `final`, `new`, `default`, `in`, `values`, `index`, a name that starts with a digit (`2fa`), or two folders that become one constant. They used to pass and write a step enum that did not compile; rename the folder and its key in `steps`.

### 0.15.0

- **The `package:http` half of `fespalier_dio` is `fespalier_http`** ([HTTP clients](http.md)).
  **Breaking, for an app that imports `package:fespalier_dio/http.dart` or `package:fespalier_dio/problem.dart`:**
  both libraries are removed (not deprecated), as the forms were in 0.11.0. The move is an import rename and a
  `pubspec.yaml` line; no member changed its name or behaviour. An app that only uses Dio changes nothing:
  `package:fespalier_dio/fespalier_dio.dart` still exports `problem.dart`.

  ```dart
  // Before (0.14.0)
  import 'package:fespalier_dio/http.dart';
  import 'package:fespalier_dio/problem.dart';

  // After (0.15.0)
  import 'package:fespalier_http/fespalier_http.dart'; // also exports problem.dart
  import 'package:fespalier_http/problem.dart';
  ```

  ```yaml
  dependencies:
    fespalier_http: # the same url and ref as fespalier
      git:
        url: https://github.com/fespalier/fespalier
        path: packages/fespalier_http
        ref: <the 0.15.0 tag, as for fespalier>
  ```

  `fespalier_dio` depends on `fespalier_http` for the write rule and the problem decoders, so a Dio app resolves it
  without listing it; list it when you import it. Run `dart pub get`, then search for `fespalier_dio/http.dart` and
  `fespalier_dio/problem.dart`.

- **`HttpWrites.isWrite` is the one write rule.** `WriteGuard` (Dio) and `WriteGuardClient` (`package:http`) both
  call it, so they agree on what a write is (any method but `GET`, `HEAD`, `OPTIONS` and `TRACE`, unless it carries
  an `Idempotency-Key`). Behaviour is unchanged.
- **`DioHttpClient`** (`package:fespalier_dio/client.dart`) is your Dio as an `http.Client`, for a package that
  takes one (`packHttpClient`, `TolgeeCdn`) and for `ref.abortable(...)`.
- **`HttpCredentials`** (`fespalier_http`) is the session for a transfer that is not an `http.Client`. `fespalier_auth`'s
  `Authorizer` implements it, and `AuthAttempt` implements `HttpAuthorization`; nothing that uses `Authorizer` changes.
- **Fakes for tests:** `FakeHttpClient` and `FakeHttpCredentials` in `package:fespalier_http/testing.dart`.
- **`fespalier_auth` depends on `fespalier_http`** (for `HttpCredentials`), so an app that lists `fespalier_auth` and
  overrides its dependencies by hand adds `fespalier_http` to the same overrides.

### 0.14.0

- **`fespalier_push` hands the app a `PushToken`, not a `String`** ([Tokens and permission](push.md#tokens-and-permission)).
  **Breaking, for an app that reads a push token.** The `String` tied the package to FCM and APNs. A `PushToken`
  has a `kind` (an open string; `PushTokenKind.fcm`, `apns`, `hms`, `unifiedpush`, `onesignal`, `mipush`, `oppo`,
  `vivo`, `honor`, `jpush` name the usual ones), a non-null `value` and `properties`, an unmodifiable
  `Map<String, String>` for what a backend needs beyond the token (OneSignal's subscription id, a UnifiedPush
  instance). It has value equality, and its `toString` prints the kind only, never the value or the properties.
  `PushSource.tokens` is a `Stream<PushToken>`, `pushToken` a `StreamProvider<PushToken>`, `onToken` takes a
  `PushToken` and `FakePushSource(token:)` and `emitToken` take one. A **revocation** (the vendor's unregister or
  token-invalidated callback) is a separate event, not a null token: `PushSource.revocations`
  (a `Stream<PushTokenRevoked>`, empty by default, so a source that never revokes changes nothing), the
  `pushTokenRevoked` provider, `onTokenRevoked` in `FespalierPush.configure` and `FakePushSource.revokeToken(kind)`.
  Telemetry is unchanged: no token event is reported, and the value and the properties never are.

  ```dart
  // Before (0.13.0)
  FespalierPush.configure(source: MyPushSource(), route: pushRoute, onToken: (String token) => api.register(token));
  // Stream<String> get tokens => messaging.onTokenRefresh;

  // After (0.14.0)
  FespalierPush.configure(
    source: MyPushSource(),
    route: pushRoute,
    onToken: (PushToken token) => api.register(token.kind, token.value, token.properties),
    onTokenRevoked: (PushTokenRevoked revoked) => api.unregister(revoked.kind, revoked.properties),
  );
  // Stream<PushToken> get tokens => messaging.onTokenRefresh.map(
  //   (value) => PushToken(kind: PushTokenKind.fcm, value: value));
  ```

  A test: `FakePushSource(token: PushToken(kind: PushTokenKind.fcm, value: 't'))`, `emitToken(PushToken(...))`.
  Every `PushSource` changes its `tokens` type; an app with no token callback changes nothing else.

### 0.12.0

- **`ready()` and `attach()` in startup.dart** ([`main()`](app-startup.md)). Opt-in, and an app that exports
  neither regenerates to the same `lib/app.main.g.dart` and the same `StartupGate`. `ready(ProviderContainer)`
  runs on the app's own container after `startup()` and before the router; `attach(GoRouter, ProviderContainer)`
  runs after the first frame that shows the router, after the adapters'. They are what a `main: manual` app
  that builds its own `ProviderContainer` writes in its `main()`; moving to the generated `main()` is moving
  that code into them. Run `fsp gen` after adding either. **`ready` and `attach` are reserved names in startup.dart now**: a helper of that name with another shape is an `fsp` error (`ready` takes one `ProviderContainer`, optional or nullable allowed, and returns `void`, `Future<void>` or `FutureOr<void>`; `attach` takes `GoRouter` and `ProviderContainer`, returns `void` and is not `async`): rename it or make it private.

### 0.11.0

- **Forms moved to the `fespalier_forms` package** ([Forms](forms.md)). `form()` and `useForm` need the
  `fespalier_forms` package. Add `fespalier_forms` under `dependencies:`, at the same git `url` and `ref` as
  `fespalier`, and run `fsp gen`: `app.g.dart` now imports `package:fespalier_forms/fespalier_forms.dart`
  (only in an app with a `form()`), and `fsp` reports an error at each `form()` until the dependency is there.
  Code that names `ActionForm`, `ActionField`, `ActionTextField`, `ActionFormFields`, `FieldCodec`,
  `ActionFormMessages`, `ActionFormValidation` or `useActionForm` imports
  `package:fespalier_forms/fespalier_forms.dart`: `package:fespalier` no longer exports them. The names and
  the behaviour are the same, and so is a page that only calls the generated `useForm`.
  `FieldErrors`, `validate()` and `optimistic()` stay in `fespalier` ([`validate()` and
  `FieldErrors`](actions.md#validate-and-fielderrors)): an app with no form changes nothing. In a repository
  checkout, `examples/features` and `examples/auth` show the dependency.
- **Drafts** ([Drafts](forms.md#drafts)). A form can keep what the user typed per route and restore it on return:
  `NicknameRoute.useForm(ref, data: p, draft: const FormDraft())`. It is opt-in, so no form changes behaviour, but
  every app with a `form()` regenerates `app.g.dart`: `useForm` takes a `FormDraft? draft` and passes the action's
  file and name, its keys and the form's field types to `useActionForm`, and a `bool`, `DateTime` or enum field gets a
  `DraftCodec`. A key of an action with a form can no longer be called `draft`. Drafts go to `formDraftStorage`, which
  is your `dataCacheStorage` unless you override it; call `clearFormDrafts` when somebody signs out.
- **Asking before unsaved changes go** ([Leaving with unsaved changes](forms.md#leaving-with-unsaved-changes)). A
  `leave.dart` that is `leaveIfClean(context, ref, page)` asks in a bottom sheet ("Keep editing", "Discard", and
  "Keep as draft" for a form with a `draft:`), and a `useForm` under a page with a `leave.dart` is the page's
  `LeaveSource` by itself. Nothing changes for an app that has no `leave.dart` (and `app.g.dart` is the same). Flutter's
  `MaterialLocalizations` are needed by the sheet: on material_ui's `MaterialApp`, override `leavePrompt`.
- **Multi-page forms** ([Multi-page forms](forms.md#multi-page-forms)). A section's `action.dart` with a `const steps`
  map is a form over several pages that share one form and one draft. It is new and opt-in: no app changes unless it
  adds one. Only a `const` map literal called `steps` (or `<action>Steps`) in an `action.dart` with a `form()` is read as one;
  a `steps` of another shape (a number, a list) is left alone. A page-less section may now
  have a `leave.dart` when it is a flow, `leaveExit` gets a `within:` there, and a `LeaveScope.onBack` handler now
  blocks the pop on the first page of a navigator too (a step of a flow is the only page of its shell's navigator).

- **A guard above a tab layout runs once, on the tab shell** (`StatefulShellRoute.redirect`), instead of being copied into each tab's route. What it decides is the same (it still runs for every location under the tabs, before the tab's own guards), but its telemetry and DevTools site is now one, named after the tab folder (`g<guard>@<tab folder>`: the `fespalier.route` of its spans is the folder's pattern, `/` for a group, not each tab's), so a dashboard that groups guard outcomes by `fespalier.route` sees the tabs merged. Run `fsp gen`; an app with no guard above its tabs changes nothing.

- **`observe.dart`'s `onEnter` can take a `RouteScope`** ([The page's scope](observability.md#the-pages-scope-routescope)).
  `RouteHooks.onEnter` is `void Function(Ref ref, RouteScope scope)?` now: every app with an `observe.dart`
  regenerates (`fsp gen`), because the generated closures read `onEnter: (ref, scope) => ...`. A hook
  you wrote keeps compiling unchanged; one that builds a `RouteHooks` by hand takes two parameters.
  `onEnter(Ref ref, {required RouteScope scope})` may call `scope.hold(provider)` (kept loaded until the
  page is gone, a parked tab included) and `scope.onLeave(callback)`. `AppRoutes.attach` takes the
  app's `ProviderContainer` in an app with an `observe.dart` too: `lib/app.main.g.dart` now gives the
  `StartupGate` `attach: AppRoutes.attach` (regenerate it with `fsp gen`), and the hooks run in the app's root
  container, where a provider overridden only in a nested `ProviderScope` reads its default.
  A scope ends, and its `onLeave` callbacks run, when its container is disposed.
  **Page ids changed for `replace`:** the lifecycle (`observe.dart`, telemetry, Sentry breadcrumbs) told a page made by
  `replace` apart by a random key, and now by the key of the page it replaces. `replace('/c/1?q=2')` on the tree page
  `/c/1` is no longer a leave and an enter; `replace('/c/2')` still is, and so are `push` and `pushReplacement`.

### 0.9.x

- **Page names** ([Transitions](layouts.md#transitions)). Every `pageBuilder:` the generated file writes
  is wrapped in `namedPage('/products/:id', () => ...)`, so a `NavigatorObserver` sees the pattern
  instead of `null` (a `remount` page used to be `:id`). Regenerate with `fsp gen`: every app's
  `app.g.dart` changes.
  **Telemetry** ([Spans around data() and actions](observability.md#spans-around-data-and-actions)). With `telemetry: true` the data provider calls `traceDataCall(ref, 'd4', id, () => data(ref, id: id), telemetry: ...)` (one closure per provider build, no `Future` and no microtask); regenerate with `fsp gen`. An app without `telemetry: true` keeps `traceData(...)`, and its file does not change.
  - A `data` span starts before `data()` runs, so its duration includes the synchronous part.
  - A `data()` that throws before it returns has a `data` span (before 0.9.0 it had none).
  - `FespalierOtel` makes data and action spans current, so the HTTP spans of `otel_http` and `otel_dio` are their children. A sink with a member named `within` of another signature must rename it.

### 0.8.1

- **`main()`** ([`main()`: app.dart, startup.dart and splash.dart](app-startup.md)). Before 0.8.1
  `fsp init` printed a `main()` that built the `ProviderScope` and the `MaterialApp.router` itself. That
  still works, and it is what `main: manual` keeps. Nothing changes until you opt in; the table in
  [app-startup.md](app-startup.md) shows where each line of a hand-written `main()` goes.
  **Telemetry** ([Turning it on](observability.md#turning-it-on)): without `telemetry: true` nothing is generated for it.

### 0.7.0

- **Deferred routes** ([Deferred routes](navigation.md#deferred-routes-a-pages-code-on-demand)): a route
  that is not deferred generates exactly the code it did before 0.7.0.

### 0.6.0

- **`remount`** ([Remounting a page](navigation.md#remounting-a-page-remount)). `never` is what
  fespalier generated before 0.6.0, and the generated code keys a page by the URL where it used to use
  go_router's `state.pageKey`.
  **`disposeRouter`** ([pumpRouter and currentLocation](testing.md#pumprouter-and-currentlocation)): a test that disposes the router itself with an `addTearDown` registered before the call, as tests written for 0.4.x do, passes `disposeRouter: false`.
- **`replace`** ([The URL as state](navigation.md#the-url-as-state-of-and-copywith)) now shows its location in the address bar and replaces the history entry; on 0.5.0 it was go_router's in every case (the address bar followed it only when no page was below it), so use `go` for URL state there.

### 0.5.0

- **Guards and redirects** ([Guards](guards.md), [redirect.dart](guards.md#redirectdart)).
  - A guard may take `Ref ref` first and runs again when what it `ref.watch`es changes. Before 0.5.0 a
    guard read once, when you navigated; `ProviderContainer c` first is that older form, still read
    once.
  - A redirect may take `Ref ref` first, or `ProviderContainer c`.
  - Menus read the older form once, when the menu asks
    ([Menus and breadcrumbs](layouts.md#menus-and-breadcrumbs-navdart)).
  - See also the `guard.dart` row of [File kinds](file-kinds.md).
- **Layout restoration** ([State restoration](layouts.md#state-restoration)): a layout's page used the
  route object's hash code as its key, so a router built again by a hot reload or a test replaced the
  layout and lost its state. Since 0.5.0 it uses a `ValueKey` made of its restoration id.
  **Prefetch** ([Typed helpers on the route](data.md#typed-helpers-on-the-route)): a prefetch used to lapse after 30 seconds without a `keepFor`, and now lasts until closed; `prefetchKeepAlive` is gone. `ref`, `keepFor`, `preload`, `of`, `maybeOf` and `copyWith` can no longer be segment or query names.
- **`pumpRouter`** ([pumpRouter and currentLocation](testing.md#pumprouter-and-currentlocation))
  disposes the router when the test ends, and the generated `AppRoutes` makes a fresh `navigatorKey` on
  each `router()` or `mount()` call without one.
