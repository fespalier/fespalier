import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fespalier/fespalier.dart' show ProviderScope;
import 'package:fespalier_image/fespalier_image.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:fespalier_transport/testing.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// A 1 x 1 PNG.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

TransportResponse _ok() => TransportResponse.fromBytes(
  statusCode: 200,
  headers: const {'content-type': 'image/png'},
  bytes: _png,
);

/// Resolves [provider] and completes with its first image or error.
Future<Object> _outcome(ImageProvider<Object> provider) {
  final done = Completer<Object>();
  provider
      .resolve(ImageConfiguration.empty)
      .addListener(
        ImageStreamListener(
          (info, _) => done.complete(info),
          onError: (error, _) => done.complete(error),
        ),
      );
  return done.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  testWidgets('it GETs the URL through the transport and decodes the bytes', (
    tester,
  ) async {
    final transport = FakeTransport((_, _) => _ok());
    final info = await tester.runAsync(
      () => _outcome(
        TransportImage('https://img.example.com/a.png', transport: transport),
      ),
    );
    expect(info, isA<ImageInfo>());
    expect((info! as ImageInfo).image.width, 1);
    final sent = transport.requests.single;
    expect(sent.method, 'GET');
    expect(sent.url.toString(), 'https://img.example.com/a.png');
    expect(sent.request.body, isNull);
  });

  testWidgets(
    'a status other than 200 is a NetworkImageLoadException with it',
    (tester) async {
      final transport = FakeTransport(
        (_, _) => fakeResponse(404, body: 'nope'),
      );
      final provider = TransportImage(
        'https://img.example.com/a.png',
        transport: transport,
      );
      final error = await tester.runAsync(() => _outcome(provider));
      expect(error, isA<NetworkImageLoadException>());
      expect((error! as NetworkImageLoadException).statusCode, 404);
      expect(error.toString(), isNot(contains('nope')));
      // A failed load is not kept: the next one asks again.
      await tester.runAsync(() => _outcome(provider));
      expect(transport.requests, hasLength(2));
    },
  );

  testWidgets('an empty body and a transport failure are errors', (
    tester,
  ) async {
    final empty = FakeTransport((_, _) => fakeResponse(200));
    expect(
      await tester.runAsync(
        () => _outcome(
          TransportImage('https://img.example.com/e.png', transport: empty),
        ),
      ),
      isA<Exception>(),
    );
    final down = FakeTransport.script([const TransportUnsent('refused')]);
    expect(
      await tester.runAsync(
        () => _outcome(
          TransportImage('https://img.example.com/d.png', transport: down),
        ),
      ),
      isA<TransportUnsent>(),
    );
  });

  test('it is keyed like NetworkImage, and by its transport', () {
    final a = FakeTransport.script(const []);
    final b = FakeTransport.script(const []);
    expect(
      TransportImage('https://x.test/1', transport: a),
      TransportImage('https://x.test/1', transport: a),
    );
    expect(
      TransportImage('https://x.test/1', transport: a).hashCode,
      TransportImage('https://x.test/1', transport: a).hashCode,
    );
    expect(
      TransportImage('https://x.test/1', transport: a),
      isNot(TransportImage('https://x.test/2', transport: a)),
    );
    expect(
      TransportImage('https://x.test/1', transport: a),
      isNot(TransportImage('https://x.test/1', transport: a, scale: 2)),
    );
    expect(
      TransportImage('https://x.test/1', transport: a),
      isNot(TransportImage('https://x.test/1', transport: b)),
    );
  });

  test('its key is available at once', () {
    final provider = TransportImage(
      'https://x.test/1',
      transport: FakeTransport.script(const []),
    );
    expect(
      provider.obtainKey(ImageConfiguration.empty),
      isA<SynchronousFuture<TransportImage>>(),
    );
  });

  testWidgets('a ResizeImage around it decodes at the size it asks for', (
    tester,
  ) async {
    final transport = FakeTransport((_, _) => _ok());
    final resize = ResizeImage(
      TransportImage('https://x.test/r.png', transport: transport),
      width: 16,
    );
    final key = await resize.obtainKey(ImageConfiguration.empty);
    final asked = Completer<bool>();
    resize.loadImage(key, (buffer, {getTargetSize}) {
      asked.complete(getTargetSize != null);
      return ui.instantiateImageCodecFromBuffer(buffer);
    });
    expect(await tester.runAsync(() => asked.future), isTrue);
  });

  testWidgets(
    'an ImageCdn with a transport loads a ResponsiveImage through it',
    (tester) async {
      final transport = FakeTransport((_, _) => _ok());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            imageCdnProvider.overrideWithValue(ImageCdn(transport: transport)),
          ],
          child: const MaterialApp(
            home: Align(
              alignment: Alignment.topLeft,
              child: ResponsiveImage(
                'https://img.example.com/p.png',
                width: 40,
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      expect(
        transport.requests.single.url.toString(),
        'https://img.example.com/p.png',
      );
    },
  );

  testWidgets(
    'an ImageCdn with neither a transport nor a factory reports and shows the error view',
    (tester) async {
      final reported = <Object>[];
      final saved = FlutterError.onError;
      FlutterError.onError = (details) => reported.add(details.exception);
      addTearDown(() => FlutterError.onError = saved);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [imageCdnProvider.overrideWithValue(const ImageCdn())],
          child: MaterialApp(
            home: Align(
              alignment: Alignment.topLeft,
              child: ResponsiveImage(
                'https://img.example.com/p.png',
                width: 40,
                errorBuilder: (context, error, retry) =>
                    Text('failed: ${error.runtimeType}'),
              ),
            ),
          ),
        ),
      );
      expect(reported.single, isA<ImageUrlError>());
      expect(find.text('failed: ImageUrlError'), findsOneWidget);
    },
  );
}
