import 'package:fespalier/fespalier.dart';

/// A write: an `action` span, whose input and result telemetry never records.
Future<String> action(
  Ref ref, {
  required int id,
  required String input,
}) async => 'order $id: $input';
