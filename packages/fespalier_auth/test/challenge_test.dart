// parseChallenges (RFC 9110, section 11.6.1) and StepUpChallenge.fromResponse (RFC 9470): pure
// functions over a header value, so every case is a string.
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, String> wwwAuthenticate(String value) => {
  'www-authenticate': value,
};

void main() {
  group('parseChallenges', () {
    test('one challenge with token and quoted parameters', () {
      expect(
        parseChallenges(
          'Bearer realm="api", error="insufficient_user_authentication", '
          'error_description="A different authentication level is required", '
          'acr_values="myACR", max_age=5',
        ),
        [
          const HttpChallenge(
            'bearer',
            params: {
              'realm': 'api',
              'error': 'insufficient_user_authentication',
              'error_description':
                  'A different authentication level is required',
              'acr_values': 'myACR',
              'max_age': '5',
            },
          ),
        ],
      );
    });

    test('the scheme and the parameter names are case-insensitive', () {
      final [challenge] = parseChallenges('BEARER Error="x", MAX_AGE=7');
      expect(challenge.scheme, 'bearer');
      expect(challenge.params, {'error': 'x', 'max_age': '7'});
    });

    test('several challenges in one value, with and without parameters', () {
      expect(
        parseChallenges(
          'Newauth realm="apps", type=1, title="Login to \\"apps\\"", '
          'Basic realm="simple", DPoP algs="ES256 PS256", Negotiate',
        ),
        [
          const HttpChallenge(
            'newauth',
            params: {'realm': 'apps', 'type': '1', 'title': 'Login to "apps"'},
          ),
          const HttpChallenge('basic', params: {'realm': 'simple'}),
          const HttpChallenge('dpop', params: {'algs': 'ES256 PS256'}),
          const HttpChallenge('negotiate'),
        ],
      );
    });

    test('several headers, as a transport joins them with ", "', () {
      final joined = [
        'DPoP algs="ES256", error="use_dpop_nonce"',
        'Bearer error="insufficient_user_authentication"',
      ].join(', ');
      expect(parseChallenges(joined).map((c) => c.scheme), ['dpop', 'bearer']);
      expect(
        parseChallenges(joined).last.params['error'],
        'insufficient_user_authentication',
      );
    });

    test('a token68, padded or not, and then another challenge', () {
      expect(parseChallenges('Basic YWxhZGRpbjpvcGVuc2VzYW1l, Bearer'), [
        const HttpChallenge('basic', token68: 'YWxhZGRpbjpvcGVuc2VzYW1l'),
        const HttpChallenge('bearer'),
      ]);
      expect(parseChallenges('Negotiate abc+/=='), [
        const HttpChallenge('negotiate', token68: 'abc+/=='),
      ]);
    });

    test('spaces around "=" and empty list elements are allowed', () {
      expect(parseChallenges(' , Bearer error = "x" ,, max_age =3 ,'), [
        const HttpChallenge('bearer', params: {'error': 'x', 'max_age': '3'}),
      ]);
    });

    test('a parameter given twice keeps its first value', () {
      expect(parseChallenges('Bearer error="a", error="b"').single.params, {
        'error': 'a',
      });
    });

    test('a comma inside a quoted string does not split it', () {
      expect(
        parseChallenges(
          'Bearer error_description="one, Basic two", error="x"',
        ).single.params,
        {'error_description': 'one, Basic two', 'error': 'x'},
      );
    });

    test('malformed input never throws, and what parses is kept', () {
      for (final value in [
        '',
        ',',
        '=',
        '"',
        'Bearer error="unterminated',
        'Bearer =x',
        'Bearer error=',
        '@@@, Bearer error="x"',
        'Bearer a b c',
        r'Bearer error="\',
      ]) {
        expect(() => parseChallenges(value), returnsNormally, reason: value);
      }
      expect(parseChallenges(''), isEmpty);
      expect(
        parseChallenges('Bearer error="unterminated').single.params['error'],
        'unterminated',
      );
      expect(
        parseChallenges('@@@, Bearer error="x"').single,
        const HttpChallenge('bearer', params: {'error': 'x'}),
      );
    });
  });

  group('StepUpChallenge.fromResponse', () {
    test(
      'reads acr_values (space-separated) and max_age (seconds) from a 401',
      () {
        expect(
          StepUpChallenge.fromResponse(
            401,
            wwwAuthenticate(
              'Bearer error="insufficient_user_authentication", '
              'acr_values="urn:mace:incommon:iap:silver phr", max_age=300',
            ),
          ),
          const StepUpChallenge(
            acrValues: ['urn:mace:incommon:iap:silver', 'phr'],
            maxAge: Duration(minutes: 5),
          ),
        );
      },
    );

    test('neither parameter: a re-proof as it is', () {
      expect(
        StepUpChallenge.fromResponse(
          401,
          wwwAuthenticate('bearer error=insufficient_user_authentication'),
        ),
        const StepUpChallenge(),
      );
    });

    test('a DPoP challenge counts, and so does one after another scheme', () {
      expect(
        StepUpChallenge.fromResponse(
          401,
          wwwAuthenticate(
            'Basic realm="x", DPoP algs="ES256", '
            'error="insufficient_user_authentication", max_age=0',
          ),
        ),
        const StepUpChallenge(maxAge: Duration.zero),
      );
    });

    test('not a step-up: another status, another error, no header, another '
        'scheme', () {
      const stepUp = 'Bearer error="insufficient_user_authentication"';
      expect(
        StepUpChallenge.fromResponse(403, wwwAuthenticate(stepUp)),
        isNull,
      );
      expect(
        StepUpChallenge.fromResponse(
          401,
          wwwAuthenticate('Bearer error="invalid_token"'),
        ),
        isNull,
      );
      expect(StepUpChallenge.fromResponse(401, const {}), isNull);
      expect(
        StepUpChallenge.fromResponse(
          401,
          wwwAuthenticate('Basic error="insufficient_user_authentication"'),
        ),
        isNull,
      );
      expect(
        StepUpChallenge.fromResponse(
          401,
          wwwAuthenticate('Basic error="insufficient_user_authentication"'),
          schemes: const {'basic'},
        ),
        const StepUpChallenge(),
      );
    });

    test('a max_age that is not a whole number of seconds is ignored', () {
      for (final age in ['-1', '1.5', 'soon', '']) {
        expect(
          StepUpChallenge.fromResponse(
            401,
            wwwAuthenticate(
              'Bearer error="insufficient_user_authentication", max_age="$age"',
            ),
          )?.maxAge,
          isNull,
          reason: age,
        );
      }
    });

    test('equality is by value, and toString names no secret', () {
      expect(
        const StepUpChallenge(
          acrValues: ['a', 'b'],
          maxAge: Duration(seconds: 1),
        ),
        const StepUpChallenge(
          acrValues: ['a', 'b'],
          maxAge: Duration(seconds: 1),
        ),
      );
      expect(
        const StepUpChallenge(acrValues: ['a', 'b']),
        isNot(const StepUpChallenge(acrValues: ['b', 'a'])),
      );
      expect(
        const StepUpChallenge(
          acrValues: ['gold'],
          maxAge: Duration(seconds: 9),
        ).toString(),
        'StepUpChallenge(acr: gold, maxAge: 9)',
      );
    });
  });
}
