// The text of every error fespalier_auth throws: the troubleshooting skill quotes them, so a
// search for the message finds the page.
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

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
    'AuthUnavailable is a ClientException, and names the cause but not the server',
    () {
      final error = AuthUnavailable(
        http.ClientException(
          'Connection refused',
          Uri.parse('https://sso.example.com/token'),
        ),
      );
      expect(error, isA<http.ClientException>());
      expect(
        error.message,
        "fespalier_auth: couldn't refresh the session: ClientException: Connection refused",
      );
      expect(error.uri, isNull);
      expect('$error', isNot(contains('sso.example.com')));
      expect(
        AuthUnavailable(StateError('x')).message,
        "fespalier_auth: couldn't refresh the session: Bad state: x",
      );
    },
  );
}
