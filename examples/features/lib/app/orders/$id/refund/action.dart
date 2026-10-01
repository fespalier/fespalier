import 'package:features/refunds.dart';
import 'package:fespalier/fespalier.dart';

/// A refund asked for: the form's `input`. `RefundRoute.submit(ref, id: 1, input: ...)` runs it
/// once and `RefundRoute.useAction(ref, id: 1)` gives a page its pending and error state.
///
/// After a success the quote (`data.dart` beside this file) loads again, so the page shows what
/// is left to refund. Nothing else is listed here: that is the default.
Future<Refund> action(Ref ref, {required int id, required RefundInput input}) =>
    ref.read(refundServerProvider).refund(id, input);
