// The foreground backend with HttpCredentials: each send is authorized, a refusal asks the
// credentials once for a re-send, at most three sends, and a credential that throws ends the
// transfer unauthorized.
import 'dart:async';

import 'package:fespalier_download/fespalier_download.dart';
import 'package:fespalier_download/testing.dart';
import 'package:fespalier_http/fespalier_http.dart';
import 'package:fespalier_http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'file_server.dart';
import 'rig.dart';

final _origin = Uri.parse('https://tiles.example.com');

void main() {
  final body = sampleBody(300);
  late FakeTransferFiles files;

  setUp(() {
    files = FakeTransferFiles();
  });

  // Answers 401 until the request carries a token that [accept] likes.
  FakeHttpClient server(bool Function(Map<String, String>) accept) =>
      FakeHttpClient((request, _) {
        if (!accept(request.headers)) return http.Response('', 401);
        return http.Response.bytes(body, 200, headers: {'etag': '"v1"'});
      });

  test(
    'each send carries what authorize gave, the request headers too',
    () async {
      final credentials = FakeHttpCredentials(origins: [_origin]);
      final client = server((h) => h['Authorization'] == 'Bearer fake');
      final c = Rig(client, files, credentials: credentials);
      await c.start(request(bytes: 300, headers: {'x-app': '1'}));
      expect(c.now, const Complete(loc, 300));
      expect(credentials.authorizeCalls, [
        'GET https://tiles.example.com/douala.pmtiles',
      ]);
      expect(credentials.retryCalls, isEmpty, reason: 'a 200 is not a refusal');
      expect(client.requests.single.headers['x-app'], '1');
      expect(client.requests.single.headers['accept-encoding'], 'identity');
    },
  );

  test('a 401 asks retry once and the second send wins', () async {
    final credentials = FakeHttpCredentials(origins: [_origin]);
    var sends = 0;
    final client = FakeHttpClient(
      (request, _) => ++sends == 1
          ? http.Response('', 401)
          : http.Response.bytes(body, 200),
    );
    final c = Rig(client, files, credentials: credentials);
    await c.start(request(bytes: 300));
    expect(c.now, const Complete(loc, 300));
    expect(credentials.authorizeCalls, hasLength(2));
    expect(credentials.retryCalls, [401]);
    expect(client.requests, hasLength(2));
    expect(files.bytesOf(dest), body);
  });

  test('a second 401 stands: Failed(unauthorized) with the status', () async {
    final credentials = FakeHttpCredentials(origins: [_origin]);
    final client = FakeHttpClient((request, _) => http.Response('', 401));
    final c = Rig(client, files, credentials: credentials);
    await c.start(request());
    expect(c.now, const Failed(DownloadFailure.unauthorized));
    expect(c.httpStatuses['douala'], 401);
    expect(client.requests, hasLength(2));
    expect(credentials.retryCalls, [401, 401]);
  });

  test('a covered origin only: others are sent no credentials', () async {
    final credentials = FakeHttpCredentials(
      origins: [Uri.parse('https://api.other.example')],
    );
    final client = FakeHttpClient(
      (request, _) => http.Response.bytes(body, 200),
    );
    final c = Rig(client, files, credentials: credentials);
    await c.start(request(bytes: 300));
    expect(c.now, const Complete(loc, 300));
    expect(
      client.requests.single.headers.containsKey('Authorization'),
      isFalse,
    );
  });

  test('never more than three sends, whatever retry says', () async {
    final credentials = _Eager();
    final client = FakeHttpClient((request, _) => http.Response('', 401));
    final c = Rig(client, files, credentials: credentials);
    await c.start(request());
    expect(client.requests, hasLength(3));
    expect(c.now, const Failed(DownloadFailure.unauthorized));
  });

  test('a refusal that is not a 4xx is never put to the credentials', () async {
    final credentials = _Eager();
    final client = FakeHttpClient((request, _) => http.Response('', 503));
    final c = Rig(client, files, credentials: credentials);
    await c.start(request());
    expect(client.requests, hasLength(1));
    expect(credentials.retryCalls, isEmpty);
    expect(c.now, const Failed(DownloadFailure.rejected));
  });

  test('authorize that throws ends unauthorized, nothing is sent', () async {
    final client = FakeHttpClient(
      (request, _) => http.Response.bytes(body, 200),
    );
    final c = Rig(client, files, credentials: _Throws(onAuthorize: true));
    await c.start(request());
    expect(c.now, const Failed(DownloadFailure.unauthorized));
    expect(client.requests, isEmpty);
  });

  test('retry that throws ends unauthorized', () async {
    final client = FakeHttpClient((request, _) => http.Response('', 401));
    final c = Rig(client, files, credentials: _Throws(onAuthorize: false));
    await c.start(request());
    expect(c.now, const Failed(DownloadFailure.unauthorized));
    expect(client.requests, hasLength(1));
  });

  test('a re-send continues from the partial file with Range', () async {
    files.putBytes(part, body.sublist(0, 100));
    files.putText(tag, '"v1"');
    final credentials = FakeHttpCredentials(origins: [_origin]);
    var sends = 0;
    final client = FakeHttpClient((request, _) {
      if (++sends == 1) return http.Response('', 401);
      return http.Response.bytes(
        body.sublist(100),
        206,
        headers: {'content-range': 'bytes 100-299/300', 'etag': '"v1"'},
      );
    });
    final c = Rig(client, files, credentials: credentials);
    await c.start(request(bytes: 300, sha256: sha256Of(body)));
    expect(c.now, const Complete(loc, 300));
    expect(client.requests.map((r) => r.headers['range']), [
      'bytes=100-',
      'bytes=100-',
    ]);
    expect(files.bytesOf(dest), body);
  });

  test(
    'the engine renews an expired grant and goes on from the kept bytes',
    () async {
      files.putBytes(part, body.sublist(0, 100));
      files.putText(tag, '"v1"');
      final client = FakeHttpClient((request, _) {
        if (request.url.host != 'fresh.example.com') {
          return http.Response('', 403);
        }
        return http.Response.bytes(
          body.sublist(100),
          206,
          headers: {'content-range': 'bytes 100-299/300', 'etag': '"v1"'},
        );
      });
      final asked = <bool>[];
      final d = Downloads(
        backend: HttpDownloadBackend(
          client: client,
          bases: defaultBases,
          files: files,
        ),
        store: MemoryDownloadStore(),
        files: TransferDownloadFiles(bases: defaultBases, files: files),
        grantor: (r, {required renewal}) {
          asked.add(renewal);
          return renewal
              ? DownloadGrant(url: Uri.parse('https://fresh.example.com/d'))
              : null;
        },
      );
      final done = Completer<DownloadStatus>();
      d.observe((id, s) {
        if (s is Complete || s is Failed) done.complete(s);
      });
      await d.open();
      await d.start(request(bytes: 300, sha256: sha256Of(body)));
      expect(await done.future, const Complete(loc, 300));
      expect(asked, [false, true]);
      expect(client.requests.map((r) => r.url.host), [
        'tiles.example.com',
        'fresh.example.com',
      ]);
      expect(client.requests.last.headers['range'], 'bytes=100-');
      expect(files.bytesOf(dest), body);
      await d.close();
    },
  );
}

// Wants every request sent again.
class _Eager implements HttpCredentials {
  final List<int> retryCalls = [];

  @override
  bool covers(Uri uri) => true;

  @override
  Future<HttpAuthorization> authorize(
    String method,
    Uri uri, {
    HttpAuthorization? previous,
  }) async => _Attempt(method, uri);

  @override
  Future<bool> retry(
    HttpAuthorization attempt, {
    required int statusCode,
    required Map<String, String> headers,
  }) async {
    retryCalls.add(statusCode);
    return true;
  }
}

class _Throws implements HttpCredentials {
  _Throws({required this.onAuthorize});

  final bool onAuthorize;

  @override
  bool covers(Uri uri) => true;

  @override
  Future<HttpAuthorization> authorize(
    String method,
    Uri uri, {
    HttpAuthorization? previous,
  }) async {
    if (onAuthorize) throw StateError('no session');
    return _Attempt(method, uri);
  }

  @override
  Future<bool> retry(
    HttpAuthorization attempt, {
    required int statusCode,
    required Map<String, String> headers,
  }) async => throw StateError('refresh failed');
}

class _Attempt implements HttpAuthorization {
  _Attempt(this.method, this.uri);

  @override
  final String method;

  @override
  final Uri uri;

  @override
  Map<String, String> get headers => const {'Authorization': 'Bearer t'};

  @override
  bool get isReplay => false;
}
