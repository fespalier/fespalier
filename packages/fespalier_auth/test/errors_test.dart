// The text of every error fespalier_auth throws: the troubleshooting skill quotes them, so a
// search for the message finds the page.
import 'package:fespalier/fespalier.dart' show DataRefusal;
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_transport/fespalier_transport.dart'
    show CredentialsUnavailable, TransportBroken;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'AuthRejected says the server refused the session, with its error and description',
    () {
      expect(
        '${const AuthRejected()}',
        'AuthRejected: the server refused the session (invalid_grant)',
      );
      expect(
        '${const AuthRejected('invalid_grant', 'Token is not active')}',
        'AuthRejected: the server refused the session (invalid_grant: Token is not active)',
      );
      expect(
        '${const AuthRejected('invalid_client')}',
        'AuthRejected: the server refused the session (invalid_client)',
      );
    },
  );

  test('AuthCancelled says the sign-in was cancelled', () {
    expect(
      '${const AuthCancelled()}',
      'AuthCancelled: the sign-in was cancelled',
    );
  });

  test('NotSignedIn is a StateError', () {
    expect(NotSignedIn(), isA<StateError>());
    expect('${NotSignedIn()}', 'Bad state: fespalier_auth: not signed in');
  });

  test(
    'AuthUnavailable is a CredentialsUnavailable, and names the cause but not the server',
    () {
      final cause = TransportBroken(
        'Connection refused',
        Uri.parse('https://sso.example.com/token'),
      );
      final error = AuthUnavailable(cause);
      expect(error, isA<CredentialsUnavailable>());
      expect(error, isA<Exception>());
      expect(error.cause, same(cause));
      expect(
        '$error',
        "AuthUnavailable: couldn't renew the session: TransportBroken: the exchange failed",
      );
      expect('$error', isNot(contains('sso.example.com')));
      expect(
        '${AuthUnavailable(StateError('x'))}',
        "AuthUnavailable: couldn't renew the session: Bad state: x",
      );
    },
  );

  test('AuthUnavailable is not an AuthRejected: the session is not lost', () {
    final Object error = AuthUnavailable(StateError('x'));
    expect(error, isNot(isA<AuthRejected>()));
    expect(error, isNot(isA<DataRefusal>()));
  });

  test('AuthRejected is a DataRefusal: a page never keeps data over it', () {
    expect(const AuthRejected(), isA<DataRefusal>());
  });

  group('AuthEnded', () {
    test('says why the session ended, with the error and the description', () {
      expect(
        '${const AuthEnded(SignOutReason.revoked)}',
        'AuthEnded: the session ended (revoked: invalid_grant)',
      );
      expect(
        '${const AuthEnded(SignOutReason.keyLost, error: 'key_gone', description: 'No key')}',
        'AuthEnded: the session ended (keyLost: key_gone: No key)',
      );
    });

    test('carries the reason, the error and the description', () {
      const ended = AuthEnded(
        SignOutReason.revoked,
        error: 'device_revoked',
        description: 'Removed',
      );
      expect(ended.reason, SignOutReason.revoked);
      expect(ended.error, 'device_revoked');
      expect(ended.description, 'Removed');
      const plain = AuthEnded(SignOutReason.expired);
      expect(plain.error, 'invalid_grant');
      expect(plain.description, isNull);
    });

    test('is an exception a backend throws, not a refusal the caller sees', () {
      const Object ended = AuthEnded(SignOutReason.revoked);
      expect(ended, isA<Exception>());
      expect(ended, isNot(isA<AuthRejected>()));
    });
  });
}
