import 'package:fespalier/fespalier.dart';
import 'package:telemetry/analytics.dart';

/// Runs after the root observe.dart's `onEnter`, for the pages of this folder only. A different
/// `id` is a different page: `/orders/1` leaves, `/orders/2` enters.
void onEnter(Ref ref, {required int id}) =>
    ref.read(views.notifier).add('order $id opened');

/// Runs before the root observe.dart's `onLeave`, with the `id` the page entered with.
void onLeave(Ref ref, {required int id}) =>
    ref.read(views.notifier).add('order $id closed');

/// The page is on top again, e.g. after a page pushed over it was popped.
void onFocus(Ref ref, {required int id}) =>
    ref.read(views.notifier).add('order $id focused');
