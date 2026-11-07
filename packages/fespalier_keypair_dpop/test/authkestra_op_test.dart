// fespalier_oidc and DpopProof against a real Authkestra OpenID Provider: examples/authkestra-op/server,
// `authkestra-op` at the commit its Cargo.toml pins, started as a process.
//
//   cd examples/authkestra-op/server && cargo build --locked
//   cd ../../../packages/fespalier_keypair_dpop && \
//     AUTHKESTRA_OP_BIN=../../examples/authkestra-op/server/target/debug/authkestra-op-demo-server \
//     flutter test test/authkestra_op_test.dart
//
// Without AUTHKESTRA_OP_BIN the file skips, saying why; with FSP_REQUIRE_AUTHKESTRA_OP=1 (CI's
// `authkestra-op` job) a missing binary fails instead, so a run cannot pass by skipping.
//
// What it proves, with the stack an app runs (OidcBackend, DpopProof over a real ES256 key,
// AuthSessionNotifier and SessionTransport): discovery finds the endpoints; the sign-in is the
// authorization code flow with PKCE S256, whose code exchange the OP refuses once with
// use_dpop_nonce and accepts with the nonce it served; the tokens are DPoP-bound (cnf.jkt); the
// API, which checks the proof and the binding with Authkestra's JwtStrategy, asks for its own
// nonce, which is one Resend; a renewal rotates the refresh token and keeps the binding; the
// sign-out revokes the refresh token. The "browser" is a few HTTP requests to the OP's demo
// /login and /authorize: a real browser (flutter_web_auth_2 and a person typing) is not part of
// what CI runs. These are plain `test`s: they use real sockets.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fespalier/fespalier.dart' show ProviderContainer;
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_keypair/testing.dart';
import 'package:fespalier_keypair_dpop/fespalier_keypair_dpop.dart';
import 'package:fespalier_oidc/fespalier_oidc.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// A running `authkestra-op-demo-server`, from the one JSON line it prints.
final class _Server {
  _Server(this.process, this.hello);

  final Process process;
  final Map<String, Object?> hello;

  Uri get issuer => Uri.parse(hello['issuer']! as String);
  Uri get api => Uri.parse(hello['api']! as String);
  String get clientId => hello['client_id']! as String;
  Uri get redirectUri => Uri.parse(hello['redirect_uri']! as String);

  static Future<_Server> start(String binary) async {
    final process = await Process.start(binary, const []);
    unawaited(process.stderr.drain<void>());
    try {
      final line = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 30));
      return _Server(process, jsonDecode(line) as Map<String, Object?>);
    } on Object {
      process.kill();
      rethrow;
    }
  }

  Future<void> stop() async {
    process.kill();
    await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }
}

/// One request and its answer, as [_Wire] saw them.
final class _Exchange {
  _Exchange(
    this.method,
    this.uri,
    this.headers,
    this.body,
    this.status,
    this.answer,
    this.text,
  );

  final String method;
  final Uri uri;

  /// The request's headers, names in lower case.
  final Map<String, String> headers;
  final String body;
  final int status;

  /// The response's headers, names in lower case.
  final Map<String, String> answer;
  final String text;

  Map<String, Object?> get json => jsonDecode(text) as Map<String, Object?>;

  /// The claims of the request's DPoP proof.
  Map<String, Object?> get proof => part(headers['dpop']!, 1);
}

/// An [HttpTransport] over dart:io that records every exchange (no package:http: this package
/// links none, not even in its tests). Redirects are never followed.
final class _Wire implements HttpTransport {
  final HttpClient _client = HttpClient();
  final List<_Exchange> log = [];

  /// The exchanges with [path], in order.
  List<_Exchange> at(String path) => [
    for (final e in log)
      if (e.uri.path == path) e,
  ];

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    final io = await _client.openUrl(request.method, request.uri);
    io.followRedirects = false;
    request.headers.forEach(io.headers.set);
    final body = request.body;
    if (body != null) io.add(body);
    final response = await io.close();
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      bytes.add(chunk);
    }
    final answer = <String, String>{};
    response.headers.forEach(
      (name, values) => answer[name] = values.join(', '),
    );
    final data = bytes.takeBytes();
    log.add(
      _Exchange(
        request.method,
        request.uri,
        {for (final e in request.headers.entries) e.key.toLowerCase(): e.value},
        body == null ? '' : utf8.decode(body),
        response.statusCode,
        answer,
        utf8.decode(data, allowMalformed: true),
      ),
    );
    return TransportResponse.fromBytes(
      statusCode: response.statusCode,
      headers: answer,
      bytes: data,
    );
  }

  void close() => _client.close(force: true);
}

/// The browser step: opens the authorization URL; with no session the OP sends it to /login,
/// where ada signs in (the demo login sets the session cookie), and the URL is opened again.
/// Returns the redirect to the app, as flutter_web_auth_2 would. [opened] records each URL.
OpenBrowser _browser(
  _Server server,
  List<Uri> opened,
) => (url, redirect) async {
  opened.add(url);
  final client = HttpClient();
  final cookies = <String>[];
  Future<HttpClientResponse> open(
    String method,
    Uri uri, [
    String? form,
  ]) async {
    final request = await client.openUrl(method, uri);
    request.followRedirects = false;
    if (cookies.isNotEmpty) request.headers.set('cookie', cookies.join('; '));
    if (form != null) {
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
      );
      request.write(form);
    }
    final response = await request.close();
    await response.drain<void>();
    for (final line in response.headers['set-cookie'] ?? const <String>[]) {
      cookies.add(line.split(';').first.trim());
    }
    return response;
  }

  try {
    var answer = await open('GET', url);
    if (answer.headers.value('location') == '/login') {
      final login = await open(
        'POST',
        server.issuer.resolve('/login'),
        'username=${server.hello['username']}&password=${server.hello['password']}',
      );
      expect(login.statusCode, 204, reason: 'the demo login accepts ada');
      answer = await open('GET', url);
    }
    final location = answer.headers.value('location');
    if (location == null) {
      fail('/authorize did not redirect (HTTP ${answer.statusCode})');
    }
    return Uri.parse(location);
  } finally {
    client.close(force: true);
  }
};

/// The app's stack: the backend, its proof and the session over [wire].
final class _App {
  _App(this.server, this.wire)
    : proof = DpopProof(signer: FakeKeypairSigner(keyId: 'authkestra')) {
    backend = OidcBackend(
      issuer: server.issuer,
      clientId: server.clientId,
      redirectUri: server.redirectUri,
      openBrowser: _browser(server, opened),
      // offline_access is what makes authkestra-op issue a refresh token.
      scopes: const ['openid', 'profile', 'email', 'offline_access'],
      transport: wire,
      proof: proof,
    );
    container = ProviderContainer(
      overrides: [
        authConfig.overrideWithValue(
          AuthConfig(
            backend: backend,
            transport: wire,
            store: MemoryTokenStore(),
            apiOrigins: [server.api],
          ),
        ),
        authInitialState.overrideWithValue(const SignedOut()),
      ],
    );
  }

  final _Server server;
  final _Wire wire;
  final DpopProof proof;
  final List<Uri> opened = [];
  late final OidcBackend backend;
  late final ProviderContainer container;

  AuthSessionNotifier get notifier => container.read(authSession.notifier);

  AuthSession get session => (container.read(authSession) as SignedIn).session;

  TokenCredential get tokens => session.credential as TokenCredential;

  /// GET /api/me through the session, as the app's data code would.
  Future<TransportResponse> me() => container
      .read(authTransport)
      .send(
        TransportRequest(
          method: 'GET',
          uri: server.api.resolve('/api/me'),
          headers: const {'Accept': 'application/json'},
        ),
      );
}

void main() {
  final binary = Platform.environment['AUTHKESTRA_OP_BIN'];
  final required = Platform.environment['FSP_REQUIRE_AUTHKESTRA_OP'] == '1';
  if (binary == null || binary.isEmpty) {
    test(
      'fespalier_oidc against authkestra-op',
      () {
        if (required) {
          fail(
            'FSP_REQUIRE_AUTHKESTRA_OP=1 but AUTHKESTRA_OP_BIN is not set: build '
            'examples/authkestra-op/server and point AUTHKESTRA_OP_BIN at authkestra-op-demo-server',
          );
        }
      },
      skip: required
          ? null
          : 'AUTHKESTRA_OP_BIN is not set (cd examples/authkestra-op/server && cargo build '
                '--locked, then AUTHKESTRA_OP_BIN=<that dir>/target/debug/authkestra-op-demo-server)',
    );
    return;
  }

  late _Server server;
  late _Wire wire;
  late _App app;
  setUpAll(() async => server = await _Server.start(binary));
  tearDownAll(() => server.stop());
  setUp(() {
    wire = _Wire();
    app = _App(server, wire);
  });
  tearDown(() {
    app.container.dispose();
    wire.close();
  });

  test(
    'discover reads the endpoints and the DPoP algorithms from authkestra-op',
    () async {
      final found = await OidcEndpoints.discover(
        server.issuer,
        transport: wire,
      );
      expect(found.authorization, server.issuer.resolve('/authorize'));
      expect(found.token, server.issuer.resolve('/token'));
      expect(found.revocation, server.issuer.resolve('/revoke'));
      expect(
        found.endSession,
        isNull,
        reason: 'authkestra-op has no end-session endpoint',
      );
      expect(found.dpopAlgorithms, contains('ES256'));
    },
  );

  test(
    'signs in with PKCE S256; the code exchange answers one use_dpop_nonce, and the tokens are bound to the key',
    () async {
      await app.notifier.signIn(const BrowserSignIn());
      final thumbprint = await app.proof.thumbprint();

      final authorize = app.opened.single.queryParameters;
      expect(authorize['response_type'], 'code');
      expect(authorize['code_challenge_method'], 'S256');
      expect(authorize['code_challenge'], hasLength(43));

      final token = wire.at('/token');
      expect(token, hasLength(2), reason: 'one refusal, one resend');
      expect(token[0].status, 400);
      expect(token[0].json['error'], 'use_dpop_nonce');
      expect(token[0].proof.containsKey('nonce'), isFalse);
      expect(token[1].status, 200);
      expect(token[1].proof['nonce'], token[0].answer['dpop-nonce']);
      expect(token[1].proof['jti'], isNot(token[0].proof['jti']));
      expect(token[1].body, contains('code_verifier='));

      final tokens = app.tokens;
      expect(tokens.tokenType, 'DPoP');
      expect(tokens.jkt, thumbprint);
      expect(tokens.refreshToken, isNotNull);
      final claims = unverifiedJwtClaims(tokens.accessToken)!;
      expect((claims['cnf']! as Map<String, Object?>)['jkt'], thumbprint);
      expect(claims['aud'], server.api.toString());
      expect(app.session.user.id, 'ada');
      // authkestra-op puts the user's attributes in an `identity` object, not in OpenID
      // Connect's standard claims (`email`, `name`, `preferred_username`), so AuthUser.email and
      // .name stay null; the claims are there for the app to read.
      expect(app.session.user.email, isNull);
      expect(
        app.session.user.claims['identity'],
        containsPair('email', 'ada@example.com'),
      );
    },
  );

  test(
    "a DPoP-bound call to the API: the API's nonce challenge is one Resend, then the nonce is kept",
    () async {
      await app.notifier.signIn(const BrowserSignIn());
      final thumbprint = await app.proof.thumbprint();

      final first = await app.me();
      expect(first.statusCode, 200);
      final body =
          jsonDecode(utf8.decode(await first.bytes())) as Map<String, Object?>;
      expect(body['sub'], 'ada');
      expect(body['jkt'], thumbprint);
      final calls = wire.at('/api/me');
      expect(calls, hasLength(2));
      expect(calls[0].status, 401);
      expect(
        calls[0].answer['www-authenticate'],
        contains('error="use_dpop_nonce"'),
      );
      expect(calls[1].headers['authorization'], startsWith('DPoP '));
      expect(calls[1].proof['nonce'], calls[0].answer['dpop-nonce']);
      expect(calls[1].proof['ath'], isA<String>());
      expect(
        wire.at('/token'),
        hasLength(2),
        reason: 'a nonce challenge is no renewal',
      );

      final second = await app.me();
      expect(second.statusCode, 200);
      expect(
        wire.at('/api/me'),
        hasLength(3),
        reason: 'the nonce the API served is reused',
      );

      // The same token with the Bearer scheme, or with no proof, is refused: it is bound.
      final token = app.tokens.accessToken;
      for (final headers in [
        {'Authorization': 'Bearer $token'},
        {'Authorization': 'DPoP $token'},
      ]) {
        final refused = await wire.send(
          TransportRequest(
            method: 'GET',
            uri: server.api.resolve('/api/me'),
            headers: headers,
          ),
        );
        expect(refused.statusCode, 401);
      }
    },
  );

  test(
    'renews with the refresh token: new tokens, the refresh token rotated, still bound to the key',
    () async {
      await app.notifier.signIn(const BrowserSignIn());
      final before = app.tokens;
      final signedIn = app.session;

      await app.notifier.credential(forceRenew: true);
      final after = app.tokens;
      expect(after.accessToken, isNot(before.accessToken));
      expect(after.refreshToken, isNotNull);
      expect(after.refreshToken, isNot(before.refreshToken));
      expect(after.jkt, before.jkt);
      final renewal = wire.at('/token').last;
      expect(renewal.status, 200);
      expect(renewal.body, contains('grant_type=refresh_token'));
      expect(
        wire.at('/token'),
        hasLength(3),
        reason: "the sign-in's nonce is still current",
      );

      final me = await app.me();
      expect(me.statusCode, 200);
      expect(
        wire.at('/api/me').last.headers['authorization'],
        'DPoP ${after.accessToken}',
      );

      // The old refresh token was spent by the rotation.
      await expectLater(
        app.backend.renew(signedIn),
        throwsA(
          isA<AuthRejected>()
              .having((e) => e.error, 'error', 'invalid_grant')
              .having(
                (e) => e.description,
                'description',
                'Invalid refresh token',
              ),
        ),
      );
    },
  );

  test(
    'a refresh token bound to a key is refused when the proof is signed by another key',
    () async {
      await app.notifier.signIn(const BrowserSignIn());
      final signedIn = app.session;
      final bound = app.tokens.jkt;
      // The key is gone (DpopProof.reset deletes it): the next proof is signed by a new one.
      await app.proof.reset();
      expect(await app.proof.thumbprint(), isNot(bound));
      await expectLater(
        app.backend.renew(signedIn),
        throwsA(
          isA<AuthRejected>()
              .having((e) => e.error, 'error', 'invalid_dpop_proof')
              .having(
                (e) => e.description,
                'description',
                'This refresh token is bound to a different DPoP key',
              ),
        ),
      );
    },
  );

  test(
    'signs out: the refresh token is revoked at the revocation endpoint',
    () async {
      await app.notifier.signIn(const BrowserSignIn());
      final signedIn = app.session;
      final refreshToken = app.tokens.refreshToken!;

      await app.notifier.signOut();
      expect(
        app.container.read(authSession),
        const SignedOut(reason: SignOutReason.user),
      );
      final revoke = wire.at('/revoke').single;
      expect(revoke.status, 200);
      expect(Uri.splitQueryString(revoke.body), {
        'token': refreshToken,
        'token_type_hint': 'refresh_token',
        'client_id': server.clientId,
      });

      await expectLater(
        app.backend.renew(signedIn),
        throwsA(
          isA<AuthRejected>()
              .having((e) => e.error, 'error', 'invalid_grant')
              .having(
                (e) => e.description,
                'description',
                'Invalid refresh token',
              ),
        ),
      );
    },
  );
}
