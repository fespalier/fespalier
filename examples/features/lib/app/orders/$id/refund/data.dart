import 'package:features/refunds.dart';
import 'package:fespalier/fespalier.dart';

/// The orders [data] was asked about; the tests read it to see whether this page was built
/// for a deep link, which it is not for `confirm/`.
final List<int> quoted = [];

/// What can still be refunded. A refund (`action.dart` beside this file) makes it stale, and
/// the page shows the new figure once it succeeds.
Future<String> data(Ref ref, {required int id}) async {
  quoted.add(id);
  final left = ref.read(refundServerProvider).left(id);
  return left == 0 ? 'Nothing left to refund' : 'Up to $left EUR back';
}
