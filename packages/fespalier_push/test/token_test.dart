import 'package:fespalier_push/fespalier_push.dart';
import 'package:fespalier_push/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PushToken', () {
    test('has value equality over kind, value and properties', () {
      final a = PushToken(
        kind: PushTokenKind.onesignal,
        value: 'v',
        properties: {'subscription_id': 's', 'x': 'y'},
      );
      final b = PushToken(
        kind: 'onesignal',
        value: 'v',
        properties: {'x': 'y', 'subscription_id': 's'},
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(PushToken(kind: 'onesignal', value: 'w')));
      expect(a, isNot(PushToken(kind: 'fcm', value: 'v')));
      expect(
        PushToken(kind: 'fcm', value: 'v'),
        isNot(PushToken(kind: 'fcm', value: 'v', properties: {'a': 'b'})),
      );
    });

    test('properties are empty by default and unmodifiable', () {
      final input = {'a': 'b'};
      final token = PushToken(kind: 'k', value: 'v', properties: input);
      expect(PushToken(kind: 'k', value: 'v').properties, isEmpty);
      expect(() => token.properties['c'] = 'd', throwsUnsupportedError);
      input['c'] = 'd';
      expect(token.properties, {'a': 'b'});
      expect(
        () => PushToken(kind: 'k', value: 'v').properties['c'] = 'd',
        throwsUnsupportedError,
      );
    });

    test('toString prints the kind only', () {
      final token = PushToken(
        kind: PushTokenKind.unifiedpush,
        value: 'SECRET-VALUE',
        properties: {'endpoint': 'https://SECRET-ENDPOINT'},
      );
      expect('$token', 'PushToken(unifiedpush)');
      expect('$token', isNot(contains('SECRET')));
      expect('${[token]}', isNot(contains('SECRET')));
    });

    test('kind is an open string with named constants', () {
      expect(PushTokenKind.fcm, 'fcm');
      expect({
        PushTokenKind.fcm,
        PushTokenKind.apns,
        PushTokenKind.hms,
        PushTokenKind.unifiedpush,
        PushTokenKind.onesignal,
        PushTokenKind.mipush,
        PushTokenKind.oppo,
        PushTokenKind.vivo,
        PushTokenKind.honor,
        PushTokenKind.jpush,
      }, hasLength(10));
      expect(PushToken(kind: 'my-vendor', value: 'v').kind, 'my-vendor');
    });
  });

  group('PushTokenRevoked', () {
    test('has value equality and unmodifiable properties', () {
      final a = PushTokenRevoked(kind: 'hms', properties: {'a': 'b'});
      final b = PushTokenRevoked(kind: 'hms', properties: {'a': 'b'});
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(PushTokenRevoked(kind: 'hms')));
      expect(PushTokenRevoked(kind: 'hms').properties, isEmpty);
      expect(() => a.properties['c'] = 'd', throwsUnsupportedError);
    });

    test('toString prints the kind only', () {
      final revoked = PushTokenRevoked(
        kind: 'unifiedpush',
        properties: {'endpoint': 'https://SECRET'},
      );
      expect('$revoked', 'PushTokenRevoked(unifiedpush)');
    });
  });

  group('FakePushSource', () {
    test('tokens: the initial one, then each refresh', () async {
      final fake = FakePushSource(
        token: PushToken(kind: 'fcm', value: '1'),
      );
      addTearDown(fake.close);
      final seen = <PushToken>[];
      final sub = fake.tokens.listen(seen.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(Duration.zero);
      fake.emitToken(PushToken(kind: 'fcm', value: '2'));
      await Future<void>.delayed(Duration.zero);
      expect(seen.map((t) => t.value), ['1', '2']);
    });

    test('revokeToken emits a revocation and forgets the token', () async {
      final fake = FakePushSource(
        token: PushToken(kind: 'fcm', value: '1'),
      );
      addTearDown(fake.close);
      final revoked = <PushTokenRevoked>[];
      final sub = fake.revocations.listen(revoked.add);
      addTearDown(sub.cancel);
      fake.revokeToken('fcm', properties: {'a': 'b'});
      await Future<void>.delayed(Duration.zero);
      expect(revoked, [
        PushTokenRevoked(kind: 'fcm', properties: {'a': 'b'}),
      ]);
      final later = <PushToken>[];
      final sub2 = fake.tokens.listen(later.add);
      addTearDown(sub2.cancel);
      await Future<void>.delayed(Duration.zero);
      expect(later, isEmpty);
    });

    test('a source that never revokes has an empty revocations stream', () {
      expect(_Silent().revocations, emitsDone);
    });
  });
}

class _Silent extends PushSource {
  @override
  Stream<PushToken> get tokens => const Stream.empty();
  @override
  Stream<PushMessage> get taps => const Stream.empty();
  @override
  PushMessage? initialTap() => null;
  @override
  Future<PushPermission> permission() async => PushPermission.denied;
  @override
  Future<PushPermission> requestPermission() async => PushPermission.denied;
}
