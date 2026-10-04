import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fespalier_sign_keypair/testing.dart';

/// The clock of the tests, and of the golden proofs (`iat` 1791028800).
final DateTime t0 = DateTime.utc(2026, 10, 3, 12);

/// A `Random` that counts 0, 1, 2, ... (modulo what is asked): the same `jti` on every run and
/// every SDK, where `Random(seed)` may change between releases.
final class CountingRandom implements Random {
  int _next = 0;

  @override
  int nextInt(int max) => _next++ % max;

  @override
  double nextDouble() => 0;

  @override
  bool nextBool() => false;
}

String b64u(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List unb64u(String value) => base64Url.decode(base64Url.normalize(value));

/// The JSON object of part [index] of a compact JWT.
Map<String, Object?> part(String jwt, int index) =>
    jsonDecode(utf8.decode(unb64u(jwt.split('.')[index])))
        as Map<String, Object?>;

/// A proof for [header] and [claims], signed with [signer]'s key: for the checks a server makes
/// on proofs `DpopProof` would never make.
Future<String> signedProof(
  FakeDpopSigner signer, {
  Map<String, Object?>? header,
  required Map<String, Object?> claims,
}) async {
  final jwk = await signer.publicJwk();
  final h = b64u(
    utf8.encode(
      jsonEncode(
        header ??
            <String, Object?>{'typ': 'dpop+jwt', 'alg': 'ES256', 'jwk': jwk},
      ),
    ),
  );
  final c = b64u(utf8.encode(jsonEncode(claims)));
  final signature = await signer.sign(Uint8List.fromList(utf8.encode('$h.$c')));
  return '$h.$c.${b64u(signature)}';
}

/// An HTTP date, as `Date` carries it.
String httpDate(DateTime time) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  String two(int n) => n.toString().padLeft(2, '0');
  final u = time.toUtc();
  return '${days[u.weekday - 1]}, ${two(u.day)} ${months[u.month - 1]} ${u.year} '
      '${two(u.hour)}:${two(u.minute)}:${two(u.second)} GMT';
}

/// What Python's `cryptography` and `hashlib` say about [FakeDpopSigner]'s keys: see the comment
/// in thumbprint_test.dart for how they were made.
const fakeJwk0 = <String, String>{
  'crv': 'P-256',
  'kty': 'EC',
  'x': 'WNEwJCFUdZpTU1Rb5Eec1I7dH3bcfk45js5xgyO_gsI',
  'y': 'BzhZPASdZG_6zkhHdtFgJPlQay4yEmAxf2CpkNA47p4',
};
const fakeThumbprint0 = 'XCW8GJrJxRT2sQyX29vGikHXwr7aK5puMdwvhd9pqNE';
const fakeThumbprint1 = 'kSFjtX3PWG7XxFarb-p54ae5WE7C7nIbuoo5V2zbE20';
