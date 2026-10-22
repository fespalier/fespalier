// TransportRequest and TransportResponse: the two values every transport passes around.
import 'dart:convert';
import 'dart:typed_data';

import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final uri = Uri.parse('https://api.example.com/items');

  group('TransportRequest', () {
    test('copyWith replaces the four fields and keeps the body', () async {
      final body = Uint8List.fromList([1, 2, 3]);
      final trigger = Future<void>.value();
      final original = TransportRequest(
        method: 'POST',
        uri: uri,
        headers: const {'a': '1'},
        body: body,
        contentLength: 3,
        abortTrigger: trigger,
        attributes: const {'k': 1},
      );

      final copy = original.copyWith(
        method: 'PUT',
        uri: Uri.parse('https://other.example.com/'),
        headers: const {'b': '2'},
        attributes: const {'z': true},
      );

      expect(copy.method, 'PUT');
      expect(copy.uri.host, 'other.example.com');
      expect(copy.headers, {'b': '2'});
      expect(copy.attributes, {'z': true});
      expect(identical(copy.body, body), isTrue);
      expect(copy.contentLength, 3);
      expect(identical(copy.abortTrigger, trigger), isTrue);
    });

    test('copyWith with nothing changes nothing', () {
      final original = TransportRequest(
        method: 'GET',
        uri: uri,
        headers: const {'a': '1'},
        attributes: const {'k': 1},
      );

      final copy = original.copyWith();

      expect(copy.method, 'GET');
      expect(copy.uri, uri);
      expect(copy.headers, {'a': '1'});
      expect(copy.attributes, {'k': 1});
    });

    test('copyWith keeps a body stream', () {
      final stream = Stream<List<int>>.value([1]);
      final copy = TransportRequest(
        method: 'POST',
        uri: uri,
        bodyStream: stream,
      ).copyWith(method: 'PUT');

      expect(identical(copy.bodyStream, stream), isTrue);
    });

    test('a request is replayable unless its body is a stream', () {
      expect(TransportRequest(method: 'GET', uri: uri).replayable, isTrue);
      expect(
        TransportRequest(
          method: 'POST',
          uri: uri,
          body: Uint8List(2),
        ).replayable,
        isTrue,
      );
      expect(
        TransportRequest(
          method: 'POST',
          uri: uri,
          bodyStream: const Stream<List<int>>.empty(),
        ).replayable,
        isFalse,
      );
    });

    test('hasBody: bytes that are not empty, or a stream', () {
      expect(TransportRequest(method: 'GET', uri: uri).hasBody, isFalse);
      expect(
        TransportRequest(method: 'POST', uri: uri, body: Uint8List(0)).hasBody,
        isFalse,
      );
      expect(
        TransportRequest(method: 'POST', uri: uri, body: Uint8List(1)).hasBody,
        isTrue,
      );
      expect(
        TransportRequest(
          method: 'POST',
          uri: uri,
          bodyStream: const Stream<List<int>>.empty(),
        ).hasBody,
        isTrue,
      );
    });

    test('toString names the method and the url', () {
      expect(
        TransportRequest(method: 'GET', uri: uri).toString(),
        'TransportRequest(GET $uri)',
      );
    });
  });

  group('TransportResponse', () {
    TransportResponse streamed(List<List<int>> chunks) => TransportResponse(
      statusCode: 200,
      headers: const {'content-type': 'text/plain'},
      body: Stream<List<int>>.fromIterable(chunks),
      reasonPhrase: 'OK',
    );

    test('bytes() joins the chunks of a streamed body', () async {
      final response = streamed([utf8.encode('he'), utf8.encode('llo')]);

      expect(response.isBuffered, isFalse);
      expect(utf8.decode(await response.bytes()), 'hello');
      expect(response.statusCode, 200);
      expect(response.reasonPhrase, 'OK');
    });

    test('buffered reads the body once and hands the response on', () async {
      final response = streamed([utf8.encode('abc')]);

      final buffered = await TransportResponse.buffered(response);

      expect(buffered.isBuffered, isTrue);
      expect(buffered.statusCode, 200);
      expect(buffered.headers, {'content-type': 'text/plain'});
      expect(buffered.reasonPhrase, 'OK');
      expect(utf8.decode(await buffered.bytes()), 'abc');
    });

    test('a buffered body can be read as often as needed', () async {
      final buffered = await TransportResponse.buffered(
        streamed([utf8.encode('abc')]),
      );

      expect(utf8.decode(await buffered.bytes()), 'abc');
      expect(utf8.decode(await buffered.bytes()), 'abc');
      expect(utf8.decode(await buffered.body.expand((c) => c).toList()), 'abc');
      expect(utf8.decode(await buffered.body.expand((c) => c).toList()), 'abc');
    });

    test('buffering a buffered response returns it as it is', () async {
      final buffered = await TransportResponse.buffered(
        streamed([
          [1],
        ]),
      );

      expect(
        identical(await TransportResponse.buffered(buffered), buffered),
        isTrue,
      );
    });

    test('fromBytes holds its bytes', () async {
      final response = TransportResponse.fromBytes(
        statusCode: 404,
        headers: const {},
        bytes: Uint8List.fromList([7, 8]),
      );

      expect(response.isBuffered, isTrue);
      expect(await response.bytes(), [7, 8]);
      expect(response.toString(), 'TransportResponse(404)');
    });

    test('a streamed body is the stream it was given', () async {
      final response = streamed([
        [1, 2],
      ]);

      expect(await response.body.expand((c) => c).toList(), [1, 2]);
    });
  });

  group('AuthorizedTransportRequest', () {
    test('authorized adds the attempt\'s headers over its own', () {
      final request = TransportRequest(
        method: 'GET',
        uri: uri,
        headers: const {'a': '1', 'Authorization': 'old'},
      );

      final sent = request.authorized(_Attempt({'Authorization': 'new'}));

      expect(sent.headers, {'a': '1', 'Authorization': 'new'});
      expect(sent.attributes, isEmpty);
    });

    test('a replay is marked in the attributes, and nothing is sent of it', () {
      final request = TransportRequest(
        method: 'GET',
        uri: uri,
        attributes: const {'k': 1},
      );

      final sent = request.authorized(_Attempt(const {}, replay: true));

      expect(sent.attributes, {'k': 1, transportReplayKey: true});
      expect(transportReplayKey, 'fespalier.auth.replay');
    });
  });

  group('TransportFailure', () {
    test('the text names the kind and never the server', () {
      final failures = <TransportFailure>[
        TransportAborted(null, Uri.parse('https://secret.example.com/')),
        TransportUnsent(null, Uri.parse('https://secret.example.com/')),
        TransportTimedOut(null, Uri.parse('https://secret.example.com/')),
        TransportBroken(null, Uri.parse('https://secret.example.com/')),
      ];

      for (final failure in failures) {
        expect(failure.toString(), startsWith(failure.runtimeType.toString()));
        expect(failure.toString(), isNot(contains('secret')));
      }
    });

    test('the cause and the uri are kept', () {
      final cause = StateError('x');
      final failure = TransportBroken(cause, uri);

      expect(failure.cause, same(cause));
      expect(failure.uri, uri);
    });
  });
}

final class _Attempt implements HttpAuthorization {
  _Attempt(this.headers, {this.replay = false});

  @override
  final Map<String, String> headers;

  final bool replay;

  @override
  bool get isReplay => replay;
}
