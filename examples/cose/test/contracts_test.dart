import 'dart:convert';
import 'dart:io';

import 'package:cose_example/src/contracts.g.dart';
import 'package:flutter_test/flutter_test.dart';

/// `lib/src/contracts.g.dart` is written by the server's `tests/contracts.rs` from the schema, as
/// `server/contracts.json` is. The Rust test fails when either is stale against the schema; this
/// one fails when the Dart constants differ from the committed JSON, so a hand edit of either is
/// caught on the Dart side too (it needs no Rust toolchain).
void main() {
  final json =
      jsonDecode(File('server/contracts.json').readAsStringSync())
          as Map<String, Object?>;
  final ops = json['ops']! as Map<String, Object?>;

  test('the Dart constants are the committed contract, op for op', () {
    expect(coseOps.keys.toSet(), ops.keys.toSet());
    for (final MapEntry(:key, :value) in ops.entries) {
      final op = value! as Map<String, Object?>;
      expect(coseOps[key]!.digest, op['digest'], reason: key);
      expect(coseOps[key]!.selector, op['selector'], reason: key);
      expect(coseOps[key]!.signed, op['signed'], reason: key);
    }
  });

  test('the wire constants are the committed ones', () {
    expect(coseAudience, json['audience']);
    expect(coseContentType, json['content_type']);
    expect(contractHeader, json['contract_header']);
  });

  test('only the registration is plain', () {
    expect(
      [
        for (final MapEntry(:key, :value) in coseOps.entries)
          if (!value.signed) key,
      ],
      ['procedure.registerDevice'],
    );
  });
}
