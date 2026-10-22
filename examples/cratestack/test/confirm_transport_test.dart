// ConfirmTransport turns the header a generated call can set into the attributes the signer reads,
// and keeps everything else of the request, the memo included.
import 'package:cratestack_example/src/confirm_transport.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart' show KeyRole;
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart'
    show DeviceSigner;
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final uri = Uri.parse('http://127.0.0.1:8788/rpc/procedure.payOrder');

  test(
    'the header asks for the user-present key, with its caption, and is not sent',
    () async {
      final inner = FakeTransport((request, body) => fakeResponse(200));
      final memo = TransportMemo();
      await ConfirmTransport(inner).send(
        TransportRequest(
          method: 'POST',
          uri: uri,
          headers: {
            'Content-Type': 'application/cbor',
            'X-Fespalier-Confirm': 'Pay order 1',
          },
          attributes: {TransportMemo.key: memo, 'app.own': 1},
        ),
      );
      final sent = inner.requests.single.request;
      expect(sent.headers, {'Content-Type': 'application/cbor'});
      expect(sent.attributes[DeviceSigner.roleAttribute], KeyRole.userPresent);
      expect(sent.attributes[DeviceSigner.reasonAttribute], 'Pay order 1');
      expect(sent.attributes['app.own'], 1);
      expect(
        sent.attributes[TransportMemo.key],
        same(memo),
        reason: 'the memo reaches the session',
      );
    },
  );

  test('a request without the header goes on as it is', () async {
    final inner = FakeTransport((request, body) => fakeResponse(200));
    final request = TransportRequest(
      method: 'GET',
      uri: uri,
      headers: {'accept': 'x'},
    );
    await ConfirmTransport(inner).send(request);
    expect(inner.requests.single.request, same(request));
  });
}
