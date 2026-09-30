import 'package:fespalier/fespalier.dart';

/// How many times [data] ran; the tests read it to see retries.
int itemFetches = 0;

/// Two segments, so the generated provider is keyed by `(shop:, id:)`.
Future<String> data(Ref ref, {required String shop, required int id}) async {
  itemFetches++;
  await Future<void>.delayed(const Duration(milliseconds: 10));
  if (id == 0) throw Exception('no item 0');
  return '$shop #$id';
}
