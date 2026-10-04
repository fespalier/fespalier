import 'package:fespalier/fespalier.dart';

/// A write: an `action` span, whose input and result telemetry never records. An order that
/// cannot be refunded ('refuse') throws: with `fespalier_sentry` installed that is an event on
/// this file and this function, and the caller gets the error too.
Future<String> action(Ref ref, {required int id, required String input}) async {
  if (input == 'refuse') {
    throw StateError('order $id cannot be refunded');
  }
  return 'order $id: $input';
}
