import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:offline/shop.dart';

/// Which order to cancel, and the version the person saw.
typedef CancelInput = ({int orderId, int expectedVersion});

/// Cancelling is the server's decision, so it is an intent: saved before it is sent, sent once under the
/// key `<id>#<attempt>`, kept (offline, or with no answer) until the server decides. `Accepted` only when
/// the server said yes; `Queued` means "will send when back online", never "cancelled". A refusal on the
/// spot is thrown and nothing is kept.
Future<IntentOutcome<Order>> cancel(
  Ref ref, {
  required CancelInput input,
}) => ref
    .read(intentQueue)
    .submit(
      RpcCall('cancelOrder', {
        'id': input.orderId,
        'expectedVersion': input.expectedVersion,
      }),
      subject:
          'order:${input.orderId}', // waits behind an undecided intent of the same order
      touches: const {'orders'}, // bumped when accepted: the list reads again
      decode: (output) => Order.fromMap(output! as Map<String, Object?>),
    );
