import 'package:fespalier/fespalier.dart';

import 'page_instance.dart';

/// A provider per page instance (since 0.13.0): [create] builds the state of one
/// [PageInstance], and the state lives as long as somebody watches it (an auto-dispose family
/// keyed by the instance). Two pushes of `/c/1` are two states, `/c/1?q=2` after `/c/1` and a
/// remount are the same one.
///
/// A parked tab or a covered page has no widget watching, so the state would be disposed:
/// [holdForPage] it from `observe.dart` to keep it until the page leaves.
///
/// ```dart
/// final chatDraft = pageProvider<String, ChatRoute>((ref, page) => '');
///
/// final draft = ref.watch(chatDraft(PageInstance.of(context, ChatRoute.of)));
/// ```
///
/// Riverpod 3 has no separate auto-dispose family type: the result is a `ProviderFamily`.
ProviderFamily<T, PageInstance<R>> pageProvider<T, R extends TypedLocation>(
  T Function(Ref ref, PageInstance<R> page) create, {
  String? name,
}) => Provider.autoDispose.family<T, PageInstance<R>>(create, name: name);

/// [pageProvider] for a `Notifier` (since 0.13.0): [create] builds the notifier of one
/// [PageInstance], which is told its instance (keep it in a field) and reads its state like any
/// notifier. Auto-dispose, keyed by the instance.
///
/// ```dart
/// class Draft extends Notifier<String> {
///   Draft(this.page);
///   final PageInstance<ChatRoute> page;
///   @override
///   String build() => '';
///   void set(String text) => state = text;
/// }
///
/// final chatDraft = pageNotifierProvider<Draft, String, ChatRoute>(Draft.new);
/// ```
NotifierProviderFamily<N, T, PageInstance<R>> pageNotifierProvider<
  N extends Notifier<T>,
  T,
  R extends TypedLocation
>(N Function(PageInstance<R> page) create, {String? name}) => NotifierProvider
    .autoDispose
    .family<N, T, PageInstance<R>>(create, name: name);

/// Keeps [provider] (a [pageProvider] of this page, say `chatDraft(page)`) alive for the whole
/// life of the page instance behind [scope] (since 0.13.0): a tab parked in the background, a
/// page covered by another, a page no widget watches. It is `scope.hold` under a name that says why; call it from an
/// `observe.dart` `onEnter`.
///
/// ```dart
/// void onEnter(Ref ref, {required int id, required RouteScope scope}) {
///   holdForPage(scope, chatDraft(PageInstance.ofScope(scope, ChatRoute(id: id))));
/// }
/// ```
///
/// A named pass-through of `scope.hold`. Needed for state the page reads but does not watch, or
/// that must outlive its widgets' watches (Riverpod 3 counts a paused subscription, so a parked
/// or covered page that watches keeps its state anyway). `onEnter` fires when a page first becomes
/// the top page, so a page under a deep-linked stack is held once it is on top.
///
/// The state is disposed when the page leaves. Throws a `StateError` once it has.
void holdForPage<T>(RouteScope scope, ProviderListenable<T> provider) =>
    scope.hold(provider);
