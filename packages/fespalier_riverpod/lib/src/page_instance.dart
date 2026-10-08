import 'package:fespalier/fespalier.dart';
import 'package:flutter/widgets.dart';

/// One page instance and its typed route (since 0.13.0), equal by [id]: `/c/1` pushed twice is
/// two keys, a query change or a `remount` of the same page is the same key.
///
/// The [id] is core's `pageInstanceId`, the identity the route lifecycle and `RouteScope.id` use.
/// The [route] is the one the key was made with: it is **not** part of equality, so a family
/// keyed by an instance keeps the route it first saw, and what changes with the query belongs to
/// the page's `data.dart`, which is keyed by the whole location.
///
/// ```dart
/// // in a page: the instance of the page being built
/// final page = PageInstance.of(context, ChatRoute.of);
/// final draft = ref.watch(chatDraft(page));
///
/// // in observe.dart: the same instance, from the scope
/// void onEnter(Ref ref, {required int id, required RouteScope scope}) {
///   final page = PageInstance.ofScope(scope, ChatRoute(id: id));
///   holdForPage(scope, chatDraft(page));
/// }
/// ```
///
/// `of` and `ofScope` give equal keys for one instance, so the page and the hook share a state.
base class PageInstance<R extends TypedLocation> {
  /// An instance with identity [id] for the page at [route].
  const PageInstance(this.id, this.route);

  /// The instance of the page [context] belongs to: [pageInstanceId] of its `GoRouterState`,
  /// and [routeOf] (the generated `XRoute.of`) for the typed route.
  ///
  /// Call it in a page or below it. It reads the router state of the context, so the widget
  /// rebuilds when the location changes, as `XRoute.of(context)` does.
  factory PageInstance.of(
    BuildContext context,
    R Function(BuildContext context) routeOf,
  ) =>
      PageInstance(pageInstanceId(GoRouterState.of(context)), routeOf(context));

  /// The instance [scope] is the scope of, for [route]: what an `observe.dart` `onEnter` has.
  factory PageInstance.ofScope(RouteScope scope, R route) =>
      PageInstance(scope.id, route);

  /// The page instance's identity, as `pageInstanceId` and `RouteScope.id` spell it.
  final String id;

  /// The typed route of the page when this key was made. Not part of equality.
  final R route;

  @override
  bool operator ==(Object other) => other is PageInstance && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'PageInstance($id)';
}

/// The [PageInstance] of the page this widget is in (since 0.13.0), made once per instance: it
/// is the same object while the page stays, whatever its query does, and a new one for another
/// instance. [route] is the generated `XRoute.of`.
///
/// ```dart
/// class ChatPage extends HookConsumerWidget {
///   const ChatPage({super.key});
///   @override
///   Widget build(BuildContext context, WidgetRef ref) {
///     final page = usePageInstance(ChatRoute.of);
///     final draft = ref.watch(chatDraft(page));
///     ...
///   }
/// }
/// ```
PageInstance<R> usePageInstance<R extends TypedLocation>(
  R Function(BuildContext context) route,
) {
  final context = useContext();
  final id = pageInstanceId(GoRouterState.of(context));
  return useMemoized(() => PageInstance<R>(id, route(context)), [id]);
}
