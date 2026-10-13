# Notification taps: fespalier_push

Since 0.13.0. A tap on a notification opens a typed route: the tap that cold-starts the app is the router's initial
location, a tap while the app runs is a `go` (or a `push`), both marked `NavigationSource.notification`. `docs/push.md`
is the page; `references/push-sources.md` has the vendor recipes (FCM, APNs, HMS, UnifiedPush, OneSignal, JPush,
Xiaomi/OPPO/vivo/Honor, a local-notifications plugin). Since 0.14.0 a token is a `PushToken`, not a `String` (below). It is an [adapter](../../fespalier/references/app-main.md): `adapters: [fespalier_push]` under
`fespalier:`, and a dependency on `fespalier_push` with the same git `url` and `ref` as `fespalier`.

## The three things an app writes

1. A `PushSource` over the vendor SDK (the recipes). **The package depends on no push SDK**: an app on OneSignal or Expo
   must not link Firebase pods.
2. A `PushRoute`, `PushTarget? Function(PushMessage)`. Usually `linkRoute(hosts: {...}, matches: (uri) =>
AppRoutes.matchUrl(uri) != null)`: the payload's `link` key, an in-app path or an https URL on your hosts, kept only
   when one of your routes matches it. A payload is untrusted: `linkRoute` refuses `//x`, `/\x`, control characters,
   foreign hosts, other schemes and credentials, and drops a URL's host and fragment. A mapping of your own must do the same
   (`PushTarget.to(OrderRoute(id: id))` from a parsed int is safe by construction).
3. One call in `main()`, **before `AppMain.run()`**: `FespalierPush.configure(source:, route:, onToken:, onTokenRevoked:)`. `launch()` runs
   before any `ProviderScope`, so a provider override cannot carry these. With `main: manual`, before `AppAdapters.zone`.

```dart
// in lib/main.dart (AppRoutes and AppMain are your generated app.g.dart and app.main.g.dart)
import 'package:fespalier_push/fespalier_push.dart';
import 'app.g.dart';
import 'app.main.g.dart';

Future<void> main() {
  FespalierPush.configure(
    source: FirebasePushSource(), // a PushSource: see push-sources.md
    route: linkRoute(hosts: {'shop.example.com'}, matches: (uri) => AppRoutes.matchUrl(uri) != null),
    onToken: (token) {/* a PushToken: send kind, value and properties to your backend */},
    onTokenRevoked: (revoked) {/* tell it to drop that registration */},
  );
  return AppMain.run();
}
```

## Behaviour to rely on, and traps

- **Cold start is `launch()`**: `initialTap()` mapped to an `InboundLaunch(location, source: notification, extra:)`. A sync
  source stays sync; a `Future` delays the first frame by one channel round trip, so `initialTap()` is a local read
  (`getInitialMessage`), never the network. `open: PushOpen.push` is ignored on a cold start.
- **Warm taps and tokens are `attach(router, container)`**: one `container.listen` each, closed with the `ProviderScope`.
  `onToken` gets the current token and each different refresh; it runs after the first frame. **Since 0.14.0 a token is a
  `PushToken`** (`kind`: an open string, `PushTokenKind.fcm` and the others name the usual ones; `value`: never null;
  `properties`: an unmodifiable `Map<String, String>` for what the backend needs beyond it), not the `String` of 0.13.0.
  `toString` prints the kind only: never `print` or log `value` or `properties` yourself either. **A revocation is its own
  event, never a null token**: `PushSource.revocations` (a `Stream<PushTokenRevoked>`, empty by default), `onTokenRevoked`,
  the `pushTokenRevoked` provider and `FakePushSource.revokeToken(kind, properties:)`. The package has **no HTTP
  code and never posts a token**, and never calls `requestPermission` (the app decides when: `requestPushPermission(ref)`).
- **A tap seen twice is opened once**, by message id, for the cold-start notification only: some Android and plugin combinations deliver it on `initialTap()` and again on `taps`. Any other tap opens, whatever its id, so give a real unique id or null, never a constant. A tap between `runApp` and the first frame can be lost, and a second router on the same container is ignored.
- **Guards still run.** A signed-out tap on a guarded page lands on the login page with `from`. Nothing is bypassed.
- **Unconfigured**: one `FlutterError` reports ``fespalier_push is listed under `fespalier: adapters:` but was never
configured: call FespalierPush.configure(source: ..., route: ...) in main() before AppMain.run()``; the adapter then does
  nothing and never throws. `AppMain.root()` in a widget test runs no `main()`: call `configure` in the test.
- **Telemetry**: `fespalier.push.open` with `fespalier.push.state` (`cold` | `warm`) and `fespalier.push.routed` (bool),
  plus `fespalier.navigation.source=notification` on the navigation. A payload, a title, a body, a message id and a token
  are never reported (no token event is reported at all) (`FespalierPushConventions`).
- **No device in CI sees a real tray tap.** The fakes prove the wiring; run a cold and a warm tap on a device before a release.

## Testing

```dart
// test/push_route_test.dart
import 'package:fespalier_push/fespalier_push.dart';
import 'package:fespalier_push/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final route = linkRoute(hosts: {'shop.example.com'}, matches: (uri) => uri.path.startsWith('/items/'));

  test('an in-app link, an https link on our host', () {
    expect(route(const PushMessage(data: {'link': '/items/2'}))?.location, '/items/2');
    expect(route(const PushMessage(data: {'link': 'https://shop.example.com/items/2?x=1#a'}))?.location, '/items/2?x=1');
  });

  test('anything else is ignored', () {
    for (final link in ['//evil.example.com/items/2', r'/\evil', 'https://other.host/items/2', '/other', 'javascript:alert(1)']) {
      expect(route(PushMessage(data: {'link': link})), isNull, reason: link);
    }
  });

  test('FakePushSource: one initial tap, taps, tokens, a revocation, no permission prompt', () async {
    final push = FakePushSource(initial: const PushMessage(id: '1'), token: PushToken(kind: PushTokenKind.fcm, value: 't1'));
    expect((await push.initialTap())?.id, '1');
    expect(await push.initialTap(), isNull);
    final taps = <String?>[];
    final sub = push.taps.listen((m) => taps.add(m.id));
    push.tap(const PushMessage(id: '2'));
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(taps, ['2']);
    expect((await push.tokens.first).value, 't1');
    final revoked = <PushTokenRevoked>[];
    final revokedSub = push.revocations.listen(revoked.add);
    push.revokeToken(PushTokenKind.fcm);
    await Future<void>.delayed(Duration.zero);
    await revokedSub.cancel();
    expect(revoked, [PushTokenRevoked(kind: PushTokenKind.fcm)]);
    expect(push.permissionRequests, 0);
    await push.close();
  });
}
```

A widget test of the whole path boots `AppMain.root(router: () => AppRoutes.router(launch: launch))` after
`FespalierPush.configure(source: fake, ...)` and `final launch = await AppAdapters.launch()`, then `fake.tap(...)` and
`pumpAndSettle()`; `examples/plugins/test/push_test.dart` is the model. Call `FespalierPush.debugReset()` in `setUp` and
`tearDown`.
