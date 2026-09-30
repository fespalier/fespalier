import 'package:fespalier/fespalier.dart';

/// How many times [data] ran; the tests read it to see retries.
int itemFetches = 0;

/// How many times item 13 ran; it fails its first two runs (see [data]).
int flakyRuns = 0;

/// Two segments, so the generated provider is keyed by `(shop:, id:)`.
Future<String> data(Ref ref, {required String shop, required int id}) async {
  itemFetches++;
  await Future<void>.delayed(const Duration(milliseconds: 10));
  if (id == 0) throw Exception('no item 0');
  if (id == 13 && flakyRuns++ < 2) throw Exception('flaky item 13');
  return '$shop #$id';
}
