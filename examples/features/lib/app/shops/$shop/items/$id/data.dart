import 'package:fespalier/fespalier.dart';

/// Two segments, so the generated provider is keyed by `(shop:, id:)`.
Future<String> data(Ref ref, {required String shop, required int id}) async {
  await Future<void>.delayed(const Duration(milliseconds: 10));
  if (id == 0) throw StateError('no item 0');
  return '$shop #$id';
}
