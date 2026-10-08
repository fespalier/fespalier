# `fespalier_riverpod`: providers per page instance

Since 0.13.0. A `data.dart` is keyed by a **location**: `/chats/1` is one provider however many times it is on screen. State
that belongs to **one page on a navigator** (a draft being typed, a selection, a sheet's choice) is not that. `/chats/1`
pushed twice is two pages and should be two states; `/chats/1?q=2` after `/chats/1`, or a `remount` of the page, is the same
page and keeps its state; a pop ends it. `package:fespalier_riverpod` keys a provider by the **page instance**, using the
identity core already computes for the route lifecycle: `pageInstanceId(GoRouterState)`, the string `RouteScope.id` reports.
It changes no generated code and adds no file kind, key or command, starts no timer and listens to nothing.

```yaml
# pubspec.yaml: the same url and the same ref as fespalier, or pub refuses to resolve
dependencies:
  fespalier:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier
      ref: <the tag of your fespalier>
  fespalier_riverpod:
    git:
      url: https://github.com/fespalier/fespalier
      path: packages/fespalier_riverpod
      ref: <the same tag>
```

(A fragment, not a sample: pub resolves the pair only at a release tag. `docs/data.md` has the annotated block.)

## Wire it

```dart
// lib/core/chat_draft.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_riverpod/fespalier_riverpod.dart';
import 'package:my_app/app.g.dart';

/// What the person has typed on one chat page. The notifier is told its page, if it needs the route.
class ChatDraft extends Notifier<String> {
  ChatDraft(this.page);

  final PageInstance<ChatRoute> page;

  @override
  String build() => '';

  void set(String text) => state = text;
}

/// One draft per page instance: auto-dispose, keyed by the `PageInstance`.
final chatDraft = pageNotifierProvider<ChatDraft, String, ChatRoute>(ChatDraft.new);
```

```dart
// lib/app/chats/$id/page.dart
import 'package:fespalier/fespalier.dart';
import 'package:flutter/material.dart';
import 'package:fespalier_riverpod/fespalier_riverpod.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/core/chat_draft.dart';

class ChatPage extends HookConsumerWidget {
  const ChatPage({super.key, required this.id});

  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // One object for the life of this page instance, whatever the query does.
    final page = usePageInstance(ChatRoute.of);
    return Scaffold(
      appBar: AppBar(title: Text('Chat $id')),
      body: Column(
        children: [
          TextField(onChanged: (text) => ref.read(chatDraft(page).notifier).set(text)),
          const DraftBadge(),
        ],
      ),
    );
  }
}

/// A widget below the page reaches the same state with `PageInstance.of`: it is equal by id.
class DraftBadge extends ConsumerWidget {
  const DraftBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = PageInstance.of(context, ChatRoute.of);
    return Text('draft: ${ref.watch(chatDraft(page))}');
  }
}
```

```dart
// lib/app/chats/$id/observe.dart
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_riverpod/fespalier_riverpod.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/core/chat_draft.dart';

/// Keep the draft while the page is on a navigator, watched or not (a parked tab, a covered page).
void onEnter(Ref ref, {required int id, required RouteScope scope}) {
  holdForPage(scope, chatDraft(PageInstance.ofScope(scope, ChatRoute(id: id))));
}
```

- **The key is equal by id, and only by id.** `PageInstance(id, route)`: two keys with one id are one provider, whatever
  `route` says. The family therefore keeps the route it was **first** made with. What changes with the query belongs to the
  page's `data.dart`, which is keyed by the whole location; do not read a query parameter from `page.route` and expect it
  to follow.
- **What an instance is** is core's rule (`pageInstanceId`, and `docs/observability.md`'s "Route lifecycle"): a page pushed
  twice is two; `/chats/1` to `/chats/2` is a new one; a query change is not; `remount: onLocation` is not; a `replace` of a
  tree page keeps the instance of the page it replaces. A page that `push` made has a random key, so it is never equal to
  the tree page at the same location.
- **`PageInstance.of(context, ChatRoute.of)`** reads the page's `GoRouterState` (so it rebuilds with the router, like
  `ChatRoute.of`) and must be called in the page or below it. **`usePageInstance`** is the same through `flutter_hooks`
  (fespalier already exports it), memoised by id. **`PageInstance.ofScope(scope, route)`** is the same key from an
  `observe.dart`, so the hook and the page share a state.
- **`pageProvider`** is the same family for a plain `Provider` (`T Function(Ref ref, PageInstance<R> page)`). Both are
  auto-dispose. Riverpod 3 has no `AutoDisposeProviderFamily`: the results are a `ProviderFamily` and a
  `NotifierProviderFamily`, both exported by `package:fespalier/fespalier.dart` since 0.13.0.
- **Without `holdForPage`** the state lives only while something watches it. Riverpod 3 counts a paused subscription, so a
  parked tab or covered page whose widgets **watch** it keeps it anyway. The hold is for state the page reads but does not
  watch (a `read` alone does not keep an auto-dispose provider), or that must outlive its widgets' watches. `onEnter` fires
  when a page first becomes the top page, so a page under a deep-linked stack is held only once it is on top.
  `holdForPage` is `scope.hold` (see `fespalier-observability`, "The page's scope"): it ends with the page, not before.
  It throws a `StateError` once the page has left, like `scope.hold`.
- **Not kept across a restart or between containers.** A draft that must survive is `dataCache` or the form drafts of
  `fespalier_forms`; a second `ProviderScope` has its own states.

## Test it

`TestPageInstance(route, id:)` (`package:fespalier_riverpod/testing.dart`) is a key for a test without a router: the default
`id` is `'test'`, the same `id` is the same key. With a router the instance is what the page builds, so the test is
`pumpRouter` and a navigation. Riverpod disposes an unlistened provider in a task of its own, so
`await tester.runAsync(container.pump)` after a navigation before you count disposals.

```dart
// test/chat_draft_test.dart
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/testing.dart';
import 'package:fespalier_riverpod/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/app.g.dart';
import 'package:my_app/core/chat_draft.dart';

void main() {
  test('a key is equal by id, so the same id is the same state', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final first = TestPageInstance(const ChatRoute(id: 1), id: 'first push');
    final second = TestPageInstance(const ChatRoute(id: 1), id: 'second push');
    final sub = container.listen(chatDraft(first), (_, _) {});
    addTearDown(sub.close);
    container.read(chatDraft(first).notifier).set('hello');
    expect(container.read(chatDraft(second)), '');
    expect(
      container.read(chatDraft(TestPageInstance(const ChatRoute(id: 1), id: 'first push'))),
      'hello',
    );
  });

  testWidgets('a query change keeps the draft, a second push is another page', (tester) async {
    final router = AppRoutes.router(initialLocation: '/chats/1');
    final container = await pumpRouter(tester, router);

    await tester.enterText(find.byType(TextField), 'hello');
    expect(find.text('draft: hello'), findsOneWidget);

    router.go('/chats/1?q=2'); // the same instance
    await tester.pumpAndSettle();
    expect(find.text('draft: hello'), findsOneWidget);

    unawaited(router.push<void>('/chats/1')); // a pushed page: another instance
    await tester.pumpAndSettle();
    expect(find.text('draft: '), findsOneWidget);

    router.pop(); // the pushed page and its draft are gone
    await tester.pumpAndSettle();
    await tester.runAsync(container.pump);
    expect(find.text('draft: hello'), findsOneWidget);
  });
}
```

- **A `ProviderContainer` of your own** (no `pumpRouter`) disposes on a zero-duration timer: `await container.pump()` before you
  count disposals. A `TestRouteScope(container)` from `package:fespalier/testing.dart` is a scope for `holdForPage` in a test
  of an `onEnter` (`scope.leave()` releases what was held).
- **A query-only `go` is the same instance only for a tree page.** After a `push`, `go` replaces the whole stack and the pushed
  page is gone; to test a query change on a pushed page use `replace`.

## Not built

A state that survives a restart (use `dataCache`, or the form drafts of `fespalier_forms`); a key that follows the query (that is
`data.dart`); a hold that outlives the page (hold it in a provider of your own).
