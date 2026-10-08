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
      ref: v0.13.1
  fespalier_push:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_push
      ref: v0.13.1
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
  FespalierPush.configure(source: MyPushSource(), route: pushRoute, onToken: sendToBackend);
  return AppMain.run();
}

// where a tap goes: the payload's `link`, kept only when one of your routes matches it
final pushRoute = linkRoute(hosts: {'shop.example.com'}, matches: (uri) => AppRoutes.matchUrl(uri) != null);
```

## Test it

```dart
final push = FakePushSource(initial: const PushMessage(id: '1', data: {'link': '/orders/42'}));
FespalierPush.configure(source: push, route: pushRoute);
push.tap(const PushMessage(id: '2', data: {'link': '/orders/43'}));
```

`examples/plugins` shows it end to end.
