# `fespalier_connectivity`: reconnects, offline banners and reachability

Since 0.9.0. `Freshness(refetchOnReconnect: true)` listens to [`reconnectSignal`](freshness-and-cache.md), which never fires by
itself. `package:fespalier_connectivity` is that signal from `connectivity_plus`, plus a `hasNetwork` provider for an offline
banner. It changes no generated code and adds no file kind, key or command; an app that does not depend on it pays nothing
for it.

```yaml
# pubspec.yaml: the same url and the same ref as fespalier, or pub refuses to resolve
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: <the tag of your fespalier>
  fespalier_connectivity:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_connectivity
      ref: <the same tag>
```

(A fragment, not a sample: pub resolves the pair only at a release tag. The root README has the annotated block.) It takes
`connectivity_plus` `>=6.0.1 <8.0.0` (6.0 made a change a `List<ConnectivityResult>`).

## Wire it

```dart
// lib/app/startup.dart
import 'package:fespalier/fespalier.dart' show reconnectSignal;
import 'package:fespalier/startup.dart';
import 'package:fespalier_connectivity/fespalier_connectivity.dart';

/// Synchronous: no first-frame cost. refetchOnReconnect (a data.dart or route.dart) now follows connectivity_plus.
List<Override> startup() => [reconnectSignal.overrideWith(ConnectivitySignal.new)];
```

```dart
// lib/app/products/$id/data.dart
import 'package:fespalier/fespalier.dart';

/// Loaded again when the device gets a network back, if the value is at least a minute old.
const freshness = Freshness(staleTime: Duration(minutes: 1), refetchOnReconnect: true);

Future<String> data(Ref ref, {required int id}) async => 'Product $id';
```

```dart
// lib/app/products/$id/page.dart
import 'package:flutter/material.dart';

class ProductPage extends StatelessWidget {
  const ProductPage({super.key, required this.data});

  final String data;

  @override
  Widget build(BuildContext context) => Text(data);
}
```

- **What fires.** `ConnectivitySignal` fires when the device goes **from no network to a network** (`[none]` to anything else).
  It does not fire on the first answer, and not on a Wi-Fi to mobile switch. Every listening data provider whose value is at
  least `staleTime` old (or any, with no `staleTime`) loads again, stale-while-revalidate: the old value stays on screen and
  `keepDataOnError` keeps the page if the reload fails. Within `staleTime` nothing loads.
- **No polling, no debounce timer.** A flapping network fires each time, but a provider that is already reloading is not
  stale, so it loads once.
- **Lifetime.** `reconnectSignal` is `autoDispose`: it lives while a `refetchOnReconnect` data provider does, and
  `ConnectivitySignal` keeps `networkConnectivity` alive through its `ref.listen`. A banner that watches `hasNetwork` keeps it
  alive too. When neither is there, the subscription to connectivity_plus is cancelled and the platform callback unregistered.
- **The web sends nothing on listen** (only `online` and `offline` events), so `networkConnectivity` asks `check()` once at
  the start (it reads `navigator.onLine`); an event that arrives before that answer wins over it.
- **iOS drops connectivity events while the app is in the background** (the plugin resyncs "on the next listen or check"), so
  `networkConnectivity` asks `check()` again on each resume, through fespalier's own `appResumeSignal`. Without that, an
  offline banner stays up after the network came back in the background: the **symptom of a hand-written signal** that listens
  to the stream only (what the README and `freshness-and-cache.md` showed before 0.9.0).
- **An error is not an error.** A stream error (C1) or a failing `check()` (C2) is printed in debug and changes nothing.

## An offline banner

`hasNetwork` is false only once the device has said "no network", and true before the first answer, so nothing flashes
offline at start. It is **not** whether the internet answers (below): say "No network", and let a failed load show its own
error. Pair it with `XRoute.watch(ref).isFromCache` for an "offline copy" label on a page that came from a `dataCache`.

```dart
// lib/offline_banner.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_connectivity/fespalier_connectivity.dart';
import 'package:flutter/material.dart';

/// "No network" while the device has none. It says nothing about the internet behind a network.
class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      ref.watch(hasNetwork) ? const SizedBox.shrink() : const Text('No network');
}
```

```dart
// lib/app/layout.dart
import 'package:flutter/material.dart';
import 'package:my_app/offline_banner.dart';

class AppLayout extends StatelessWidget {
  const AppLayout({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Column(children: [const OfflineBanner(), Expanded(child: child)]);
}
```

## Test it

`FakeConnectivity` is a `ConnectivitySource`: `set`, `offline()` and `online([via])` deliver a change **synchronously**, `check()`
answers `now` (and counts in `checks`), `listenerCount` is how many listen, and nothing is sent on listen (like the web).
Override `connectivitySource` with it, and `reconnectSignal` with `ConnectivitySignal.new` (`pumpRouter` does not run
`startup()`).

```dart
// test/connectivity_test.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_connectivity/fespalier_connectivity.dart';
import 'package:fespalier_connectivity/testing.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/app.g.dart';

void main() {
  testWidgets('the banner follows the network, with no navigation', (tester) async {
    final fake = FakeConnectivity();
    await pumpRouter(
      tester,
      AppRoutes.router(),
      overrides: [connectivitySource.overrideWithValue(fake)],
    );
    expect(find.text('No network'), findsNothing);
    fake.offline();
    await tester.pump();
    expect(find.text('No network'), findsOneWidget);
    fake.online();
    await tester.pump();
    expect(find.text('No network'), findsNothing);
    expect(currentLocation(tester), '/');
  });

  testWidgets('a reconnect loads a stale product again, a fresh one not', (tester) async {
    final fake = FakeConnectivity();
    await pumpRouter(
      tester,
      AppRoutes.router(initialLocation: '/products/1'),
      overrides: [
        connectivitySource.overrideWithValue(fake),
        reconnectSignal.overrideWith(ConnectivitySignal.new),
      ],
    );
    expect(find.text('Product 1'), findsOneWidget);
    fake.offline();
    fake.online(); // within the minute: the value is fresh
    await tester.pumpAndSettle();
    expect(fake.checks, 1, reason: 'only the first answer asked the platform');

    await tester.pump(const Duration(minutes: 2));
    fake.offline();
    fake.online(); // from no network to a network, after the staleTime: it loads again
    await tester.pumpAndSettle();
    expect(find.text('Product 1'), findsOneWidget);
  });

  testWidgets('a resume asks the platform again: iOS drops events in the background', (tester) async {
    final fake = FakeConnectivity();
    await pumpRouter(
      tester,
      AppRoutes.router(),
      overrides: [connectivitySource.overrideWithValue(fake)],
    );
    fake.now = const [ConnectivityResult.none]; // went offline in the background; the event was dropped
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('No network'), findsOneWidget);
  });
}
```

- **A widget test that reaches the plugin without that override fails**, with Flutter's report `while activating platform stream on
channel dev.fluttercommunity.plus/connectivity_status` (C3). A page that shows `hasNetwork` needs the fake, and so does
  `fsp test`'s `test/routes/setup.dart` when a route's page shows a banner:
  `connectivitySource.overrideWithValue(FakeConnectivity())`.
- A `ProviderContainer` of your own (no `pumpRouter`) disposes on a zero-duration timer, and a provider derived from another
  recomputes on the same scheduler: `await tester.pump(const Duration(milliseconds: 1))` where a plain `pump()` shows
  nothing. Without a `WidgetsBinding` (a bare `test()`), `networkConnectivity` still builds: the resume repair is simply
  not there.

## Connectivity is not reachability

- **Connectivity** (this package, and `navigator.onLine` on the web) answers "is a network interface up?": local, instant and
  event-driven. connectivity_plus says so itself: its result "only gives you the radio status".
- **Reachability** answers "does the server I need answer?". Only a request can tell. **Connected but unreachable:** a captive
  portal (hotel Wi-Fi before its login page), a router with no uplink, a VPN that is down, a firewall, the server down.
  **Reachable over a link the OS reports oddly:** a VPN reported as `other` on iOS, the iOS simulator's missed Wi-Fi events.
- **What that means:** `refetchOnReconnect` on connectivity can fire on a captive portal; the reload fails and `keepDataOnError`
  keeps the page. `hasNetwork == false` is reliable ("no network at all"); `true` promises nothing.
- **fespalier ships no reachability**: it needs a request to **your** server, not a third party's (privacy, and a third party
  answering says nothing about yours), and any polling is a timer. `internet_connection_checker_plus` is an alternative an
  app may plug in as its own `RefetchSignal`, knowing it polls on its `checkInterval` while listened.

## A reachability recipe (compiled)

One request to the app's own API on each connectivity change and on each resume, never on a timer, and a `RefetchSignal` that
fires when the API answers again. Any HTTP answer counts (the server is there); only a failed request is "unreachable". The
request's own OS-level timeout applies: a shorter `.timeout()` is the app's own timer, and its choice.

```yaml
# pubspec.yaml dependencies
  http: ^1.2.0
```

```dart
// lib/reachability.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_connectivity/fespalier_connectivity.dart';
import 'package:http/http.dart' as http;

/// The client the check uses: a test overrides it.
final reachabilityClient = Provider<http.Client>((ref) => http.Client());

/// Whether the app's own API answers: asked when connectivity_plus reports a change and when the app resumes, never on a
/// timer. Any HTTP answer counts (the server is there); only a failed request is "unreachable".
final apiReachable = FutureProvider.autoDispose<bool>((ref) async {
  final links = ref.watch(networkConnectivity);
  if (links != null && links.contains(ConnectivityResult.none)) return false;
  ref.watch(appResumeSignal);
  final client = ref.watch(reachabilityClient);
  try {
    await client.head(Uri.parse('https://api.example.com/health'));
    return true;
  } on Object {
    return false;
  }
});

/// A reconnect signal on reachability instead of connectivity: fires when the API answers again.
class ReachableSignal extends RefetchSignal {
  @override
  int build() {
    ref.listen(apiReachable, (previous, next) {
      if (previous?.value == false && next.value == true) fire();
    });
    return 0;
  }
}
```

```dart
// in lib/app/startup.dart (a fragment: reachability instead of connectivity)
List<Override> startup() => [reconnectSignal.overrideWith(ReachableSignal.new)];
```

```dart
// test/reachability_test.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_connectivity/fespalier_connectivity.dart' show connectivitySource;
import 'package:fespalier_connectivity/testing.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/reachability.dart';

void main() {
  testWidgets('the signal fires when the API answers again, on a resume', (tester) async {
    var up = false;
    var asked = 0;
    final client = MockClient((request) async {
      asked++;
      if (!up) throw http.ClientException('unreachable');
      return http.Response('', 204);
    });
    final container = await pumpRouter(
      tester,
      AppRoutes.router(),
      overrides: [
        connectivitySource.overrideWithValue(FakeConnectivity()),
        reachabilityClient.overrideWithValue(client),
        reconnectSignal.overrideWith(ReachableSignal.new),
      ],
    );
    final fires = <int>[];
    container.listen(reconnectSignal, (_, next) => fires.add(next));
    Future<void> settle() async {
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));
    }

    await settle();
    expect(container.read(apiReachable).value, isFalse);
    expect(fires, isEmpty, reason: 'the first answer is not a reconnect');

    up = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle();
    expect(container.read(apiReachable).value, isTrue);
    expect(fires, [1]);
    expect(asked, 2, reason: 'one request at the start, one on the resume: no timer');
  });
}
```

`internet_connection_checker_plus` is not used here: it polls on its `checkInterval`. The recipe asks when something changes,
and a captive portal that answers (any HTTP answer, even a redirect page) still counts as "reachable": check the status or a
body marker of your own `/health` if that matters.

## Traps

- **A hand-written signal that listens to the stream only** misses the web's first state and iOS's background events: the
  banner says online when it is offline (or the other way round) until the next change. Use the package, or add the `check()`
  on start and on resume.
- **A second `Connectivity()` listener of your own beside the package** is the trap connectivity_plus warns about: it is a
  singleton, and "when a second instance is created, the first instance will not be able to listen to the EventChannel".
- **`hasNetwork` is not "online".** It says "a network interface is up" and nothing more. Do not gate a request on it.
- **`reconnectSignal` is only alive while some `refetchOnReconnect` data is.** An override on an app with no such data
  subscribes to nothing, and a test that overrides it but builds no such provider never reaches the plugin.

The messages are in [`fespalier-troubleshooting`](../../fespalier-troubleshooting/SKILL.md) (its
`diagnostics-flags-storage-network.md` page). `examples/features` has `refetchOnReconnect` on `teams/$teamId/route.dart`, the
override in `startup.dart` and `test/offline_test.dart`.
