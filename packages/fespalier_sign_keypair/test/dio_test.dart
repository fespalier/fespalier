// The device signature under a real Dio: a Dio of the app's own, with dio_smart_retry, sending
// through fespalier_dio's TransportAdapter over SessionTransport. Every retry reaches the session
// again, so every send is signed afresh over the bytes Dio finally sends. Plain test(): Dio
// starts its chain with Timer.run. (a), (b) and (c) of fespalier#267 for Dio.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_dio/fespalier_dio.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart' show KeyRole;
import 'package:fespalier_sign_keypair/fespalier_sign_keypair.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

String hex(List<int> bytes) => sha256.convert(bytes).toString();

Dio dioOver(Rig rig) {
  final dio = Dio()..httpClientAdapter = TransportAdapter(rig.transport);
  dio.interceptors.add(
    RetryInterceptor(
      dio: dio,
      retries: 3,
      retryDelays: const [Duration.zero, Duration.zero, Duration.zero],
      retryEvaluator: DefaultRetryEvaluator(defaultRetryableStatuses).evaluate,
    ),
  );
  return dio;
}

void main() {
  late Rig rig;
  late Dio dio;

  setUp(() async {
    rig = Rig.create();
    await rig.enrol();
    dio = dioOver(rig);
  });

  test(
    '(a) no send carries an Authorization header, whatever the body',
    () async {
      await dio.get<String>('$audience/orders');
      await dio.post<String>('$audience/orders', data: {'a': 1});
      await dio.put<String>(
        '$audience/cbor',
        data: Uint8List.fromList([0xa1, 0x61, 0x61, 0x01]),
        options: Options(contentType: 'application/cbor'),
      );
      await dio.post<String>(
        '$audience/upload',
        data: FormData.fromMap({
          'title': 'x',
          'file': MultipartFile.fromBytes([1, 2, 3], filename: 'a.bin'),
        }),
      );
      expect(rig.api.seen, hasLength(4));
      for (final seen in rig.api.seen) {
        expect(seen.lowerHeaders.keys, isNot(contains('authorization')));
        expect(
          seen.lowerHeaders.keys,
          containsAll(['x-attestation', 'x-signature']),
        );
      }
      rig.expectAllVerified();
    },
  );

  test('(b) JSON: the signature covers the bytes Dio encoded', () async {
    await dio.post<String>(
      '$audience/orders?x=1',
      data: {'name': 'é€', 'n': 1},
    );
    final seen = rig.api.seen.single;
    expect(seen.lowerHeaders['content-type'], startsWith('application/json'));
    expect(seen.verified!.claims['bdh'], hex(seen.body));
    expect(jsonDecode(utf8.decode(seen.body)), {'name': 'é€', 'n': 1});
    rig.expectAllVerified();
  });

  test('(b) raw bytes (CBOR-like) are signed as they are', () async {
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
    await dio.put<String>(
      '$audience/cbor',
      data: cbor,
      options: Options(contentType: 'application/cbor'),
    );
    final seen = rig.api.seen.single;
    expect(seen.body, cbor);
    expect(seen.verified!.claims['bdh'], hex(cbor));
  });

  test(
    '(b) multipart: the signature covers the finalized bytes, boundary included',
    () async {
      await dio.post<String>(
        '$audience/upload',
        data: FormData.fromMap({
          'title': 'photo',
          'file': MultipartFile.fromBytes(
            List<int>.generate(300, (i) => i % 251),
            filename: 'p.bin',
          ),
        }),
      );
      final seen = rig.api.seen.single;
      expect(
        seen.lowerHeaders['content-type'],
        startsWith('multipart/form-data; boundary='),
      );
      expect(
        utf8.decode(seen.body, allowMalformed: true),
        contains('name="title"'),
      );
      expect(seen.verified!.claims['bdh'], hex(seen.body));
      rig.expectAllVerified();
    },
  );

  test('a streamed Dio body is a clear ArgumentError', () async {
    final error = await dio
        .post<String>(
          '$audience/upload',
          data: Stream.value(Uint8List.fromList([1, 2, 3])),
          options: Options(headers: {Headers.contentLengthHeader: 3}),
        )
        .then<Object?>((_) => null, onError: (Object e) => e);
    expect(
      error,
      isA<DioException>().having((e) => e.error, 'cause', isA<ArgumentError>()),
    );
    expect(rig.api.seen, isEmpty);
  });

  group('(c) dio_smart_retry', () {
    test('every retried GET carries a fresh jti the API accepts', () async {
      rig.api.script.addAll([fakeResponse(503), fakeResponse(503)]);
      final response = await dio.get<String>('$audience/orders?page=1');
      expect(response.statusCode, 200);
      expect(rig.api.seen, hasLength(3));
      expect(rig.api.verifiedJtis.toSet(), hasLength(3));
      expect(rig.api.seen.map((s) => s.signature).toSet(), hasLength(3));
      expect(
        rig.api.seen.map((s) => s.attestation).toSet(),
        hasLength(1),
        reason: 'the attestation is sent unchanged',
      );
      rig.expectAllVerified();
    });

    test(
      'a retried JSON write carries the same body bytes and a new signature each time',
      () async {
        rig.api.script.addAll([fakeResponse(503), fakeResponse(503)]);
        final response = await dio.put<String>(
          '$audience/orders/1',
          data: {'qty': 2},
          options: Options(headers: {'Idempotency-Key': 'k1'}),
        );
        expect(response.statusCode, 200);
        expect(rig.api.seen, hasLength(3));
        expect(rig.api.seen.map((s) => hex(s.body)).toSet(), hasLength(1));
        expect(rig.api.verifiedJtis.toSet(), hasLength(3));
        expect(
          rig.api.seen.map((s) => s.lowerHeaders['idempotency-key']).toSet(),
          {'k1'},
        );
      },
    );

    test('a retried CBOR write is signed afresh over the same bytes', () async {
      rig.api.script.add(fakeResponse(503));
      final cbor = Uint8List.fromList([0xa1, 0x01, 0xff]);
      await dio.post<String>(
        '$audience/cbor',
        data: cbor,
        options: Options(contentType: 'application/cbor'),
      );
      expect(rig.api.seen.map((s) => s.body), [cbor, cbor]);
      expect(rig.api.verifiedJtis.toSet(), hasLength(2));
    });

    test(
      'a retried multipart upload is signed afresh over the bytes of each send',
      () async {
        rig.api.script.add(fakeResponse(503));
        final response = await dio.post<String>(
          '$audience/upload',
          data: FormData.fromMap({
            'file': MultipartFile.fromBytes([1, 2, 3, 4], filename: 'a.bin'),
          }),
        );
        expect(response.statusCode, 200);
        expect(rig.api.seen, hasLength(2));
        rig.expectAllVerified();
        expect(rig.api.verifiedJtis.toSet(), hasLength(2));
      },
    );
  });

  group('the session under Dio', () {
    test(
      '(d) an expired attestation: one renewal, the request sent again signed afresh',
      () async {
        rig.api.script.add(refusal(401, 'attestation_expired'));
        final response = await dio.post<String>(
          '$audience/orders',
          data: {'a': 1},
        );
        expect(response.statusCode, 200);
        expect(rig.server.renewals, 1);
        expect(rig.api.seen, hasLength(2));
        expect(rig.api.verifiedJtis.toSet(), hasLength(2));
      },
    );

    test(
      '(e) a confirmed-dead 401 signs out and deletes the keys; the Dio call fails',
      () async {
        rig.api.script.add(refusal(401, 'key_not_bound'));
        await expectLater(
          dio.get<String>('$audience/orders'),
          throwsA(isA<DioException>()),
        );
        expect(rig.state, const SignedOut(reason: SignOutReason.keyLost));
        expect(rig.ambient.deletes, 1);
      },
    );

    test('(g) a user-present request: Options(extra) picks the key', () async {
      final before = rig.userPresent!.prompts;
      await dio.post<String>(
        '$audience/pay',
        data: {'amount': 5},
        options: Options(
          extra: {
            DeviceSigner.roleAttribute: KeyRole.userPresent,
            DeviceSigner.reasonAttribute: 'Confirm the payment',
          },
        ),
      );
      expect(rig.userPresent!.prompts, before + 1);
      expect(rig.userPresent!.lastReason, 'Confirm the payment');
      expect(
        rig.api.seen.single.attestation,
        rig.credential.attestation(KeyRole.userPresent)!.jws,
      );
      rig.expectAllVerified();
    });
  });
}
