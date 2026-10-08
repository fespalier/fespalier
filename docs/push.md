# Push notifications: fespalier_push

`fespalier_push` (since 0.13.0) makes a tap on a notification open a typed route: the tap that **cold-starts** the app is the router's initial location, and a tap while the app **runs or sits in the background** is a navigation, both marked `source=notification` in [telemetry](observability.md#telemetry). It is an [adapter](adapters.md): you list it under `fespalier: adapters:`, and the generated `main()` calls it.

It is the routing half of push, and only that. Where the push comes from is a `PushSource` that you hand to it. **The vendor SDK is not a dependency**: Firebase Messaging (and a local-notifications plugin, or an APNs-only source) is a compiled recipe in the `fespalier-routing` skill, so an app that uses OneSignal or Expo does not link Firebase pods. The package has no HTTP code and never posts a token: `onToken` is yours.

## Install

Add `fespalier_push` under `dependencies:` next to `fespalier`, with the same git `url` and the same `ref`: pub resolves the two to one package only if they are the same repository dependency. The snippet, kept at the release's tag, is in [`packages/fespalier_push/README.md`](../packages/fespalier_push/README.md). Then list it as an adapter and run `fsp gen`:

```yaml
# pubspec.yaml
fespalier:
  telemetry: true # optional: reports the navigation's source
  adapters: [fespalier_push]
```

Any `onEnter` makes go_router parse every navigation asynchronously, and an app with adapters has one (see [Adapters in the generated `main()`](adapters.md#adapters-in-the-generated-main)); an app without adapters keeps go_router's simplest path.

## Configure

An adapter takes no options from the pubspec, and `launch()` runs before any `ProviderScope` exists, so the app's own code reaches it through one static call in `main()`, before `AppMain.run()` ([Adapters that need your code](adapters.md#adapters-that-need-your-code)):

```dart
// lib/main.dart
Future<void> main() {
  FespalierPush.configure(source: MyPushSource(), route: pushRoute, onToken: sendToBackend,
    onTokenRevoked: dropFromBackend);
  return AppMain.run();
}
```

- `source` is a `PushSource` (below), `route` maps a payload to a place, `onToken` and `onTokenRevoked` (since 0.14.0) are optional.
- Calling `configure` twice replaces (a hot restart runs `main()` again).
- **Unconfigured, the adapter says so once and does nothing**: one `FlutterError` reports `fespalier_push is listed under `fespalier: adapters:` but was never configured: call FespalierPush.configure(source: ..., route: ...) in main() before AppMain.run()`, and `launch()` and `attach()` do nothing. It never throws out of them: an adapter must not stop an app from starting.
- With `main: manual`, call `configure` in your own `main()` before `AppAdapters.zone`.

A `PushSource` is what a push provider gives the package:

| Member                                   | What it is                                                                                                                                                                       |
| ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `initialTap()`                           | The tap that cold-started the app, answered once. A local read (`getInitialMessage`): it runs before the first frame, so a `Future` delays that frame by one channel round trip. |
| `taps`                                   | Taps while the app runs or is in the background.                                                                                                                                 |
| `received`                               | Messages delivered in the foreground (default: none). Nothing is shown for them; `pushReceived` exposes them.                                                                    |
| `tokens`                                 | The current token, then each refresh, as a `PushToken` (a `String` before 0.14.0).                                                                                               |
| `revocations`                            | A token that stopped being valid, as a `PushTokenRevoked` (since 0.14.0; default: none). A source maps the vendor's unregister or invalidation callback to it.                   |
| `permission()` and `requestPermission()` | The platform's answer, and its prompt. The package never calls `requestPermission`.                                                                                              |

## Mapping a payload

`PushRoute` is `PushTarget? Function(PushMessage message)`: a `PushTarget(location, extra:, open:)` (or `PushTarget.to(OrderRoute(id: 42))`) to open, or `null` to open the app and navigate nowhere. `PushOpen.go` (the default) replaces the stack as a link does, `PushOpen.push` goes on top of the current page. A mapping that throws is reported and counts as `null`.

The common mapping is `linkRoute`: the payload's `link` key holds an in-app path or an `https` URL on one of `hosts`, and it is kept only when `matches` accepts it:

```dart
final pushRoute = linkRoute(
  hosts: {'shop.example.com'},
  matches: (uri) => AppRoutes.matchUrl(uri) != null,
);
```

Anything else is ignored and never navigated to, by the same rules as [`returnTo`](guards.md#sending-people-back) and stricter: a scheme-relative `//host/x`, a backslash, a control character, a foreign host, a scheme other than `https`, credentials in the URL. A URL's host is dropped and so is its fragment. A payload is untrusted input: a notification can be sent by anyone who has the app's token or topic.

## Cold start and taps

- **A cold start** is answered in `launch()`: `initialTap()` is mapped to an `InboundLaunch` with `source: NavigationSource.notification`, so the router is built at that location (over the platform's initial route) and the first navigation is marked. `open:` does not apply: a cold start is always the initial location. The guards run as for any link: a signed-out tap on a guarded page lands on the login page with `from`.
- **A warm tap** is handled in `attach(router, container)`: the package subscribes to `taps` with one `container.listen`, so the subscription goes with the `ProviderScope`, and calls `router.go` or `router.push` inside `navigateFrom(NavigationSource.notification, ...)`.
- **A tap seen twice is opened once**: some Android and plugin combinations deliver the cold-start notification both as the launch and on the tap stream. The package remembers the message id of the launch and drops the first tap with the same id, once; any other tap opens, even one with an id it has seen. A message without an id cannot be deduplicated, and a source must give a real, unique id or null (never a constant).
- A tap that arrives between `runApp` and the first frame that shows the router (when `attach` subscribes) is lost on a source whose `taps` is a broadcast stream. That is a window of one frame, and only taps while the app is already running can fall in it.
- One subscription per `ProviderScope`: a second router built on the same container (a test) is ignored, and the first router gets the taps.
- `fespalier.push.routed` says the mapping gave a place and the navigation call was made; on a cold start another adapter's `launch()` may still have won.
- On the web `launch()` is never asked, and a notification click is an ordinary URL.

Telemetry (the package's own names, `FespalierPushConventions`): `fespalier.push.open` with `fespalier.push.state` (`cold` or `warm`) and, on its end, `fespalier.push.routed` (`bool`). The navigation it starts carries `fespalier.navigation.source=notification`. A payload, a title, a body, a message id and a token (its kind included, its value and properties never) are not reported: no token event is.

## Tokens and permission

- A token is a `PushToken` (since 0.14.0; it was a `String`, which tied the package to FCM and APNs): `kind` (an open string, with `PushTokenKind.fcm`, `apns`, `hms`, `unifiedpush`, `onesignal`, `mipush`, `oppo`, `vivo`, `honor` and `jpush` for the usual ones), `value` (never null) and `properties` (an unmodifiable `Map<String, String>`, empty by default) for what the backend needs beyond the token: OneSignal's subscription id, a UnifiedPush instance. It has value equality, and its `toString` prints the kind only, never the value or the properties. The same goes for `PushTokenRevoked`.
- `onToken(token)` is called with the current token and again for each different refresh. It runs in the app's container, after the first frame: send the token to your backend there. The package has no HTTP code, so it cannot post a token by itself.
- `pushToken` is the same stream as a `StreamProvider<PushToken>`, for an app that prefers Riverpod.
- **A revocation is its own event, not a null token** (since 0.14.0): `onTokenRevoked(revoked)` and the `pushTokenRevoked` `StreamProvider<PushTokenRevoked>` come from `PushSource.revocations`. Tell the backend to drop the registration (`revoked.kind` and `revoked.properties` say which). A source with no unregister callback leaves `revocations` out. Two equal revocations in a row are heard once.
- The vendor recipes (FCM, APNs, HMS, UnifiedPush, OneSignal, JPush, flutter_mix_push) are in the fespalier-routing skill's `push-sources.md`; each gives the `kind` and the `properties` its backend needs.
- The permission prompt is yours: `requestPushPermission(ref)` shows the platform's prompt and refreshes `pushPermission`, a `FutureProvider` over `permission()`. Ask at a moment the person understands (after they enable alerts), not at start.

## Testing

`package:fespalier_push/testing.dart` has `FakePushSource` (`initial:`, `token:`, `permissionAnswer:`; `tap(message)`, `deliver(message)`, `emitToken(PushToken)`, `revokeToken(kind, properties:)`, `permissionRequests`) and `pushTestOverrides(source)`. A widget test boots the app as it runs, with `configure` called first, because `AppMain.root()` runs no `main()`:

```dart
FespalierPush.configure(source: fake, route: pushRoute);
final launch = await AppAdapters.launch(); // what main() does before runApp
await tester.pumpWidget(AppMain.root(router: () => AppRoutes.router(launch: launch)));
fake.tap(const PushMessage(id: '1', data: {'link': '/orders/42'}));
await tester.pumpAndSettle();
```

Call `FespalierPush.debugReset()` in `setUp` and `tearDown`. [`examples/plugins`](../examples/plugins) tests a cold start, a warm tap, a guard, a foreign link, a repeated id, the token and its revocation through `AppMain.root()`; no device is needed. What no test can see: a real tap from the system tray, cold and warm, on each platform. Do it on a device before a release.
