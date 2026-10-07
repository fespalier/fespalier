import 'package:fespalier/fespalier.dart';
import 'package:telemetry/analytics.dart';
import 'package:telemetry/app.g.dart';

/// Runs after the root observe.dart's `onEnter`, for the pages of this folder only. A different
/// `id` is a different page: `/orders/1` leaves, `/orders/2` enters.
///
/// [scope] is this page instance's: the order stays loaded for as long as the page is on a
/// navigator (a parked tab included), and the callback runs when the page is gone.
void onEnter(Ref ref, {required int id, required RouteScope scope}) {
  scope.hold(OrderRoute.data(id));
  ref.read(views.notifier).add('order $id opened');
  scope.onLeave(() => scopeLog.add('order $id scope left'));
}

/// Runs before the root observe.dart's `onLeave`, with the `id` the page entered with.
void onLeave(Ref ref, {required int id}) =>
    ref.read(views.notifier).add('order $id closed');

/// The page is on top again, e.g. after a page pushed over it was popped.
void onFocus(Ref ref, {required int id}) =>
    ref.read(views.notifier).add('order $id focused');
