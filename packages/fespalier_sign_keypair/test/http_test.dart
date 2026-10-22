// The device signature through package:http: SessionTransport over fespalier_http's
// HttpClientTransport over a MockClient, and package:http code (TransportClient, RetryClient)
// above it. The MockClient is the wire: what it sees is what a server would. (a), (b) and (c)
// of fespalier#267 for package:http.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart' show KeyRole;
import 'package:fespalier_http/fespalier_http.dart';
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:fespalier_sign_keypair/verify.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/retry.dart';
import 'package:http/testing.dart';

import 'support.dart';

/// What reached the MockClient, and a client above the session.
final class Wire {
  Wire(this.rig, this.requests, this.client);
  final Rig rig;
  final List<http.Request> requests;
  final http.Client client;
}

Wire wire({bool withUserPresent = true}) {
  final requests = <http.Request>[];
  final rig = Rig.create(
    withUserPresent: withUserPresent,
    below: (api) => HttpClientTransport(
      MockClient((request) async {
        requests.add(request);
        final answer = await api.send(
          TransportRequest(
            method: request.method,
            uri: request.url,
            headers: request.headers,
            body: request.bodyBytes,
          ),
        );
        return http.Response.bytes(
          await answer.bytes(),
          answer.statusCode,
          headers: answer.headers,
          request: request,
        );
      }),
    ),
  );
  return Wire(rig, requests, TransportClient(rig.transport));
}

String hex(List<int> bytes) => sha256.convert(bytes).toString();

void main() {
  late Wire w;

  setUp(() async {
    w = wire();
    await w.rig.enrol();
  });

  test(
    '(a) no request reaches the wire with an Authorization header',
    () async {
      final url = Uri.parse('$audience/orders');
      await w.client.get(url);
      await w.client.post(
        url,
        body: '{"a":1}',
        headers: {'content-type': 'application/json'},
      );
      await w.client.put(
        url,
        body: Uint8List.fromList([0xa1, 0x61, 0x61, 0x01]),
        headers: {'content-type': 'application/cbor'},
      );
      expect(w.requests, hasLength(3));
      for (final request in w.requests) {
        expect(
          request.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('authorization')),
        );
        expect(
          request.headers.keys.map((k) => k.toLowerCase()),
          containsAll(['x-attestation', 'x-signature']),
        );
      }
      w.rig.expectAllVerified();
    },
  );

  test(
    '(b) JSON is accepted, and the signature covers exactly the bytes on the wire',
    () async {
      await w.client.post(
        Uri.parse('$audience/orders?x=1'),
        body: jsonEncode({'name': 'é€'}),
        headers: {'content-type': 'application/json'},
      );
      final wireBody = w.requests.single.bodyBytes;
      final seen = w.rig.api.seen.single;
      expect(seen.verified!.claims['bdh'], hex(wireBody));
      expect(seen.body, wireBody);
      w.rig.expectAllVerified();
    },
  );

  test('(b) raw bytes (CBOR-like, not UTF-8) are accepted', () async {
    final cbor = Uint8List.fromList([
      0xa2,
      0x61,
      0x61,
      0xff,
      0xfe,
      0x61,
      0x62,
      0x80,
      0x00,
    ]);
    await w.client.put(
      Uri.parse('$audience/cbor'),
      body: cbor,
      headers: {'content-type': 'application/cbor'},
    );
    expect(w.rig.api.seen.single.verified!.claims['bdh'], hex(cbor));
    w.rig.expectAllVerified();
  });

  test(
    '(b) a multipart body is finalized once, and the signature covers the finalized bytes',
    () async {
      final request =
          http.MultipartRequest('POST', Uri.parse('$audience/upload'))
            ..fields['title'] = 'photo'
            ..files.add(
              http.MultipartFile.fromBytes(
                'file',
                List<int>.generate(300, (i) => i % 251),
                filename: 'p.bin',
              ),
            );
      final response = await w.client.send(request);
      expect(response.statusCode, 200);
      final onWire = w.requests.single;
      expect(
        onWire.headers['content-type'],
        startsWith('multipart/form-data; boundary='),
      );
      expect(
        utf8.decode(onWire.bodyBytes, allowMalformed: true),
        contains('name="title"'),
      );
      final seen = w.rig.api.seen.single;
      expect(seen.verified!.claims['bdh'], hex(onWire.bodyBytes));
      w.rig.expectAllVerified();
      // And the bytes that went out are the bytes that were signed: changing one is refused.
      final tampered = Uint8List.fromList(onWire.bodyBytes)..[40] ^= 1;
      final sent = seen.request;
      final keys = await w.rig.server.issuerKeys;
      expect(
        () => verifyDeviceSignature(
          method: 'POST',
          uri: sent.uri,
          headers: sent.headers,
          body: tampered,
          profile: profile,
          issuerKeys: keys,
          seenJtis: {},
        ),
        throwsA(
          isA<DeviceSignatureInvalid>().having((e) => e.claim, 'claim', 'bdh'),
        ),
      );
    },
  );

  test(
    'a streamed body through package:http is a clear ArgumentError',
    () async {
      final request = http.StreamedRequest(
        'POST',
        Uri.parse('$audience/upload'),
      )..sink.add([1, 2, 3]);
      unawaited(request.sink.close());
      await expectLater(w.client.send(request), throwsA(isA<ArgumentError>()));
      expect(w.requests, isEmpty);
    },
  );

  test(
    '(c) RetryClient: every retried GET carries a fresh jti the API accepts',
    () async {
      w.rig.api.script.addAll([fakeResponse(503), fakeResponse(503)]);
      final retrying = RetryClient(
        w.client,
        retries: 3,
        delay: (_) => Duration.zero,
        when: (r) => r.statusCode == 503,
      );
      final response = await retrying.get(Uri.parse('$audience/orders?page=1'));
      expect(response.statusCode, 200);
      expect(w.requests, hasLength(3));
      expect(w.rig.api.seen, hasLength(3));
      expect(w.rig.api.verifiedJtis.toSet(), hasLength(3));
      expect(w.rig.api.seen.map((s) => s.signature).toSet(), hasLength(3));
      expect(
        w.requests.map(
          (r) => r.headers.keys
              .map((k) => k.toLowerCase())
              .contains('authorization'),
        ),
        everyElement(isFalse),
      );
    },
  );

  test(
    '(c) an expired attestation under RetryClient: renewed once, and the next attempt is signed afresh',
    () async {
      w.rig.api.script.add(refusal(401, 'attestation_expired'));
      final retrying = RetryClient(
        w.client,
        retries: 3,
        delay: (_) => Duration.zero,
        // A package:http retrier sends a copy as a stream, which is sent once: the session
        // renews after the 401 and hands it back, so the retrier's next attempt works.
        when: (r) => r.statusCode == 503 || r.statusCode == 401,
      );
      expect(
        (await retrying.get(Uri.parse('$audience/orders'))).statusCode,
        200,
      );
      expect(w.rig.server.renewals, 1);
      expect(w.rig.api.seen, hasLength(2));
      expect(w.rig.api.verifiedJtis.toSet(), hasLength(2));
    },
  );

  test(
    'a user-present request signs with the user-present key and its attestation',
    () async {
      final before = w.rig.userPresent!.prompts;
      final response = await w.rig.send(
        '/pay',
        method: 'POST',
        attributes: {DeviceSigner.roleAttribute: KeyRole.userPresent},
      );
      expect(response.statusCode, 200);
      expect(w.rig.userPresent!.prompts, before + 1);
      expect(
        w.requests.single.headers['X-Attestation'] ??
            w.requests.single.headers['x-attestation'],
        w.rig.credential.attestation(KeyRole.userPresent)!.jws,
      );
    },
  );
}
