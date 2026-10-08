# fespalier_riverpod

Riverpod providers **per page instance** for [fespalier](https://github.com/fespalier/fespalier) (since 0.13.0): `/c/1` pushed
twice is two states, `/c/1?q=2` after `/c/1` or a `remount` of the page is the same one, a pop disposes it, and state a page reads but does not watch can be kept with `holdForPage`; a parked tab that
watches its state keeps it anyway. The key is core's `pageInstanceId`, the identity the route lifecycle and
`RouteScope.id` already use. No dependency beyond fespalier (Riverpod, `flutter_hooks` and go_router come through it), no timer,
no listener.

The docs cover all of it: [Providers per page instance](https://github.com/fespalier/fespalier/blob/main/docs/data.md#providers-per-page-instance-fespalier_riverpod).
This page is the short version.

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
      ref: v0.12.0
  fespalier_riverpod:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_riverpod
      ref: v0.12.0
```

<!-- x-release-please-end -->

## Use it

```dart
// A provider per page instance: a Notifier that is told which page it belongs to.
final chatDraft = pageNotifierProvider<ChatDraft, String, ChatRoute>(ChatDraft.new);

// In the page (or below it): the instance of this page, from the generated ChatRoute.of.
final page = PageInstance.of(context, ChatRoute.of); // usePageInstance(ChatRoute.of) in a hook widget
final draft = ref.watch(chatDraft(page));

// lib/app/chats/$id/observe.dart: keep it while the page is on a navigator, watched or not.
void onEnter(Ref ref, {required int id, required RouteScope scope}) {
  holdForPage(scope, chatDraft(PageInstance.ofScope(scope, ChatRoute(id: id))));
}
```

- `PageInstance` is equal by id: the typed `route` it carries is the one it was first made with and is not part of equality.
- `pageProvider` is the same for a plain `Provider`; both are auto-dispose families (Riverpod 3: a `ProviderFamily` and a
  `NotifierProviderFamily`).
- `package:fespalier_riverpod/testing.dart` has `TestPageInstance(route, id:)` for a test without a router.

The package starts no timer and listens to nothing (`test/no_timers_test.dart`).
