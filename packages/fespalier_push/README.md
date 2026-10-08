# fespalier_push

Notification taps for [fespalier](https://github.com/fespalier/fespalier) (since 0.13.0): the tap that cold-starts the app and a tap while it runs open typed routes, marked `source=notification`. It is an adapter (`fespalier: adapters: [fespalier_push]`). The push SDK is not a dependency: you give it a `PushSource`, and Firebase Messaging is a recipe in the `fespalier-routing` skill. It has no HTTP code and never posts a token (`onToken` is yours), starts no timer, and its one listener is the adapter's `container.listen`.

The docs cover all of it: [Push notifications](https://github.com/fespalier/fespalier/blob/main/docs/push.md). This page is the short version.

## Install

Add it next to fespalier, with the same `url` and the same `ref`: pub resolves the two to one package only if they are
the same repository dependency.

<!-- x-release-please-start-version -->

```yaml
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: v0.14.0
  fespalier_push:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_push
      ref: v0.14.0
```

<!-- x-release-please-end -->

## Wire it

```yaml
# pubspec.yaml
fespalier:
  adapters: [fespalier_push]
```

```dart
// lib/main.dart: configure before the adapters run
Future<void> main() {
  FespalierPush.configure(source: MyPushSource(), route: pushRoute, onToken: sendToBackend,
    onTokenRevoked: dropFromBackend);
  return AppMain.run();
}

// where a tap goes: the payload's `link`, kept only when one of your routes matches it
final pushRoute = linkRoute(hosts: {'shop.example.com'}, matches: (uri) => AppRoutes.matchUrl(uri) != null);
```

## Tokens (since 0.14.0)

`onToken` and the `pushToken` provider hand over a `PushToken`: an open `kind` (`PushTokenKind.fcm`, `apns`,
`hms`, `unifiedpush`, `onesignal`, ... or your own string), a non-null `value` and `properties` for what a
backend needs beyond it (OneSignal's subscription id, a UnifiedPush instance). Its `toString` prints the kind
only. A token that stops being valid arrives separately, as a `PushTokenRevoked` (`PushSource.revocations`,
`pushTokenRevoked`, `onTokenRevoked`), never as a null token. Before 0.14.0 the token was a `String`: see
[Migration](https://github.com/fespalier/fespalier/blob/main/docs/migration.md).

## Test it

```dart
final push = FakePushSource(initial: const PushMessage(id: '1', data: {'link': '/orders/42'}));
FespalierPush.configure(source: push, route: pushRoute);
push.tap(const PushMessage(id: '2', data: {'link': '/orders/43'}));
```

`examples/plugins` shows it end to end.
