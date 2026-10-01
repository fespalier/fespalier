import 'package:fespalier/fespalier.dart';

/// The orders [data] was asked about; the tests read it to see whether this page was built
/// for a deep link, which it is not for `confirm/`.
final List<int> quoted = [];

Future<String> data(Ref ref, {required int id}) async {
  quoted.add(id);
  return 'Up to ${id * 10} EUR back';
}
