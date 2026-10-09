// HttpTransfer and HttpDownloadBackend against a fake server and in-memory files: a whole
// download, a resume with Range from a partial file, a server that ignores Range, checks that
// fail, refusals, pause and resume, a restart whose bytes are on disk, cancel in the middle, and
// the real dart:io store. Ported from fespalier_maps' file pack tests, which are the behaviour
// spec of the transfer.
import 'dart:async';
import 'dart:io';

import 'package:fespalier_download/fespalier_download.dart';
import 'package:fespalier_download/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'file_server.dart';
import 'rig.dart';

void main() {
  final body = sampleBody(450);
  late FileServer server;
  late FakeTransferFiles files;

  Rig make({http.Client? client, TransferFiles? store}) =>
      Rig(client ?? server.client, store ?? files);

  setUp(() {
    server = FileServer(body);
    files = FakeTransferFiles();
  });

  group('a whole download', () {
    test(
      'arrives in .part and is moved to the destination when whole',
      () async {
        final c = make();
        final packs = c;
        await packs.start(request(bytes: 450, sha256: sha256Of(body)));
        expect(c.now, const Complete(loc, 450));
        expect(files.bytesOf(dest), body);
        expect(files.bytesOf(part), isNull);
        expect(
          files.textOf(tag),
          isNull,
          reason: 'the validator goes with the partial file',
        );
        expect(files.renames, ['$part -> $dest']);
        expect(server.requests, hasLength(1));
        expect(server.requests.single.containsKey('range'), isFalse);
        expect(server.requests.single['accept-encoding'], 'identity');
        expect(c.history.last.$2, isA<Complete>());
        expect(c.history.map((e) => e.$2), contains(isA<Running>()));
      },
    );
  });

  group('resume with Range', () {
    test('a partial file is continued from its size, with If-Range', () async {
      files.putBytes(part, body.sublist(0, 120));
      files.putText(tag, '"v1"');
      final c = make();
      await c.start(request(bytes: 450, sha256: sha256Of(body)));
      expect(server.requests.single['range'], 'bytes=120-');
      expect(server.requests.single['if-range'], '"v1"');
      expect(c.now, const Complete(loc, 450));
      expect(files.bytesOf(dest), body, reason: 'appended at the right offset');
    });

    test('the first progress report starts at the partial size', () async {
      files.putBytes(part, body.sublist(0, 225));
      files.putText(tag, '"v1"');
      final gate = Completer<void>();
      server.beforeChunk = (i) => gate.future;
      final c = make();
      final done = c.start(request(bytes: 450));
      await pumpEventQueue();
      expect(c.now, const Running(225, 450));
      gate.complete();
      await done;
    });

    test(
      'a server that ignores Range sends the whole body, and the transfer restarts at 0',
      () async {
        server.honourRange = false;
        files.putBytes(part, body.sublist(0, 120));
        final c = make();
        await c.start(request(bytes: 450, sha256: sha256Of(body)));
        expect(server.requests.single['range'], 'bytes=120-');
        expect(c.now, const Complete(loc, 450));
        expect(files.bytesOf(dest), body, reason: 'not 120 bytes twice');
      },
    );

    test(
      'a file that changed on the server (If-Range does not match) is fetched whole',
      () async {
        files.putBytes(part, List<int>.filled(120, 9));
        files.putText(tag, '"old"');
        final c = make();
        await c.start(request(bytes: 450, sha256: sha256Of(body)));
        expect(server.requests.single['if-range'], '"old"');
        expect(files.bytesOf(dest), body);
        expect(c.now, isA<Complete>());
      },
    );

    test('a partial file already whole skips the network', () async {
      files.putBytes(part, body);
      final c = make();
      await c.start(request(bytes: 450, sha256: sha256Of(body)));
      expect(server.requests, isEmpty);
      expect(files.bytesOf(dest), body);
    });

    test(
      'a partial file longer than the file is dropped before asking',
      () async {
        files.putBytes(part, List<int>.filled(900, 1));
        final c = make();
        await c.start(request(bytes: 450));
        expect(server.requests.single.containsKey('range'), isFalse);
        expect(files.bytesOf(dest), body);
      },
    );

    test(
      'a 416 to a partial file the server cannot continue restarts once from 0',
      () async {
        // Without a size to compare: the server's file is shorter than the partial.
        files.putBytes(part, List<int>.filled(900, 1));
        final c = make();
        await c.start(request(sha256: sha256Of(body)));
        expect(server.requests.map((r) => r['range']), ['bytes=900-', null]);
        expect(files.bytesOf(dest), body);
      },
    );

    test(
      'a 416 that says the partial file is the whole file finishes it',
      () async {
        files.putBytes(part, body);
        final c = make();
        await c.start(request(sha256: sha256Of(body)));
        expect(server.requests.single['range'], 'bytes=450-');
        expect(files.bytesOf(dest), body);
        expect(c.now, const Complete(loc, 450));
      },
    );

    test('a 416 on a fresh download is a refusal', () async {
      server.forceStatus = 416;
      final c = make();
      await c.start(request());
      expect(c.now, const Failed(DownloadFailure.rejected));
    });

    test('a 416 that survives the restart is a refusal, not a loop', () async {
      files.putBytes(part, body.sublist(0, 10));
      server.forceStatus = 416;
      final c = make();
      await c.start(request(sha256: sha256Of(body)));
      expect(c.now, const Failed(DownloadFailure.rejected));
      expect(server.requests, hasLength(2));
    });

    test(
      'a 206 that starts somewhere else than asked restarts from 0',
      () async {
        files.putBytes(part, body.sublist(0, 100));
        files.putText(tag, '"v1"');
        var first = true;
        final odd = http.StreamedResponse(
          Stream.value(body.sublist(300)),
          206,
          headers: {'content-range': 'bytes 300-449/450'},
        );
        final c = make(
          client: _Switch((r) {
            if (first) {
              first = false;
              return odd;
            }
            return null;
          }, server),
        );
        await c.start(request(bytes: 450));
        expect(files.bytesOf(dest), body);
      },
    );
  });

  group('checks', () {
    test(
      'a size that is not the request\'s fails and deletes the partial file',
      () async {
        final c = make();
        await c.start(request(bytes: 449));
        expect(c.now, const Failed(DownloadFailure.sizeMismatch));
        expect(files.paths, isEmpty);
      },
    );

    test(
      'a body longer than the size the request names is a mismatch',
      () async {
        server.body = sampleBody(450);
        final c = make(
          client: _Switch(
            (r) => http.StreamedResponse(
              Stream.value(body),
              200,
              // The server announces nothing: the count is what gives it away.
            ),
            server,
          ),
        );
        await c.start(request(bytes: 300));
        expect(c.now, const Failed(DownloadFailure.sizeMismatch));
        expect(files.paths, isEmpty);
      },
    );

    test(
      'a hash that does not match fails, deletes the file, and moves nothing',
      () async {
        final c = make();
        await c.start(request(bytes: 450, sha256: '0' * 64));
        expect(c.now, const Failed(DownloadFailure.hashMismatch));
        expect(files.paths, isEmpty);
        expect(files.renames, isEmpty);
      },
    );

    test('the hash may be written in capitals', () async {
      final c = make();
      await c.start(request(sha256: sha256Of(body).toUpperCase()));
      expect(c.now, isA<Complete>());
    });

    test('a retry after a hash mismatch starts clean, without Range', () async {
      final c = make();
      final packs = c;
      await packs.start(request(sha256: '0' * 64));
      await packs.retry('douala');
      expect(server.requests.map((r) => r['range']), [null, null]);
    });

    test(
      'the server announcing another size than the request names fails before the bytes',
      () async {
        final c = make();
        await c.start(request(bytes: 300));
        expect(c.now, const Failed(DownloadFailure.sizeMismatch));
        expect(files.bytesOf(part), isNull);
      },
    );
  });

  group('refusals and failures', () {
    for (final code in [404, 500, 503]) {
      test('a $code is Failed(rejected) and keeps the partial file', () async {
        files.putBytes(part, body.sublist(0, 100));
        server.forceStatus = code;
        final c = make();
        await c.start(request());
        expect(c.now, const Failed(DownloadFailure.rejected));
        expect(files.bytesOf(part), body.sublist(0, 100));
      });
    }

    test('no connection is Failed(network)', () async {
      server.connectError = http.ClientException('no route');
      final c = make();
      await c.start(request());
      expect(c.now, const Failed(DownloadFailure.network));
    });

    test(
      'a connection that breaks keeps what arrived, and resume goes on from it',
      () async {
        server.breakAfter = 200;
        final c = make();
        final packs = c;
        await packs.start(request(bytes: 450, sha256: sha256Of(body)));
        expect(c.now, const Failed(DownloadFailure.network));
        expect(files.bytesOf(part), body.sublist(0, 200));
        await packs.retry('douala');
        expect(server.requests.last['range'], 'bytes=200-');
        expect(c.now, const Complete(loc, 450));
        expect(files.bytesOf(dest), body);
      },
    );

    test(
      'a body that ends short without an error is Failed(network)',
      () async {
        final c = make(
          client: _Switch(
            (r) => http.StreamedResponse(
              Stream.value(body.sublist(0, 200)),
              200,
              contentLength: 450,
            ),
            server,
          ),
        );
        await c.start(request());
        expect(c.now, const Failed(DownloadFailure.network));
        expect(files.bytesOf(part), body.sublist(0, 200));
      },
    );

    test('a write the device refuses is Failed(storage)', () async {
      files.failWrites = const FileSystemException('No space left on device');
      final c = make();
      await c.start(request());
      expect(c.now, const Failed(DownloadFailure.storage));
    });

    test(
      'a move that fails is Failed(storage) and the partial file stays whole',
      () async {
        files.failRename = const FileSystemException('denied');
        final c = make();
        await c.start(request());
        expect(c.now, const Failed(DownloadFailure.storage));
        expect(files.bytesOf(part), body);
      },
    );

    test(
      'where there are no files (the web) it fails before any request',
      () async {
        files.unsupported = true;
        final c = make();
        await c.start(request());
        expect(c.now, const Failed(DownloadFailure.unsupported));
        expect(server.requests, isEmpty);
      },
    );

    test(
      'an invalid request reaches neither the disk nor the network',
      () async {
        final c = make();
        final packs = c;
        for (final bad in [
          request(id: 'a', sha256: 'xyz'),
          request(id: 'a', bytes: -1),
          request(id: 'a', path: ''),
          request(id: 'a', path: '../x'),
          request(id: 'a', url: Uri.parse('ftp://x/y')),
          request(id: 'a', url: Uri.parse('/relative')),
        ]) {
          expect(bad.isValid, isFalse);
          await packs.start(bad);
          expect(c.statusOf('a'), const Failed(DownloadFailure.invalidRequest));
        }
        expect(server.requests, isEmpty);
        expect(files.paths, isEmpty);
      },
    );

    test('two ids cannot share a destination', () async {
      final c = make();
      final packs = c;
      await packs.start(request());
      await packs.start(request(id: 'other'));
      expect(c.statusOf('other'), const Failed(DownloadFailure.invalidRequest));
      expect(c.now, isA<Complete>());
    });

    test('a request for an unmetered network is refused: the foreground '
        'cannot tell', () async {
      final c = make();
      expect(
        await c.backend.enqueue(request(network: DownloadNetwork.unmetered)),
        isFalse,
      );
      expect(server.requests, isEmpty);
      expect(c.backend.capabilities.unmetered, isFalse);
    });

    test(
      'a 401 and a 403 are Failed(unauthorized), with the status code',
      () async {
        for (final code in [401, 403]) {
          server.forceStatus = code;
          final c = make();
          await c.start(request());
          expect(c.now, const Failed(DownloadFailure.unauthorized));
          expect(c.httpStatuses['douala'], code);
        }
      },
    );
  });

  group('pause and resume', () {
    test(
      'pause stops at the next chunk, keeps the partial file, and resume uses Range',
      () async {
        final gate = Completer<void>();
        server.beforeChunk = (i) => i == 1 ? gate.future : Future<void>.value();
        final c = make();
        final packs = c;
        final done = packs.start(request(bytes: 450, sha256: sha256Of(body)));
        await pumpEventQueue();
        expect(c.now, isA<Running>());
        final paused = packs.pause('douala');
        gate.complete();
        await paused;
        await done;
        final status = c.now as Paused;
        expect(
          status.received,
          100,
          reason: 'the request was aborted at chunk 1',
        );
        expect(status.total, 450);
        expect(files.bytesOf(part), body.sublist(0, 100));
        expect(files.bytesOf(dest), isNull);
        server.beforeChunk = null;
        await packs.resume('douala');
        expect(server.requests.last['range'], 'bytes=100-');
        expect(c.now, const Complete(loc, 450));
        expect(files.bytesOf(dest), body);
      },
    );

    test(
      'a start of a paused download does nothing: resume is the verb',
      () async {
        final gate = Completer<void>();
        server.beforeChunk = (i) => i == 1 ? gate.future : Future<void>.value();
        final c = make();
        final packs = c;
        final done = packs.start(request());
        await pumpEventQueue();
        final paused = packs.pause('douala');
        gate.complete();
        await paused;
        await done;
        final before = server.requests.length;
        await packs.start(request());
        expect(server.requests, hasLength(before));
        expect(c.now, isA<Paused>());
      },
    );

    test('pause and resume of what is not running do nothing', () async {
      final c = make();
      final packs = c;
      await packs.pause('nothing');
      await packs.resume('nothing');
      await packs.start(request());
      await packs.pause('douala');
      await packs.resume('douala');
      expect(c.now, isA<Complete>());
      expect(server.requests, hasLength(1));
    });

    test(
      'a pause asked while the request is in flight pauses before the first byte',
      () async {
        server.hold = Completer<void>().future;
        final c = make();
        final packs = c;
        final done = packs.start(request());
        await pumpEventQueue();
        final paused = packs.pause('douala');
        await paused;
        await done;
        expect(c.now, const Paused(0));
        expect(files.bytesOf(part), isNull);
      },
    );
  });

  group('a restart', () {
    test(
      'the bytes are on disk and the next attempt continues with Range',
      () async {
        final gate = Completer<void>();
        server.beforeChunk = (i) => i == 2 ? gate.future : Future<void>.value();
        final first = make();
        final running = first.start(request(bytes: 450));
        await pumpEventQueue();
        expect(files.bytesOf(part), body.sublist(0, 200));
        // The app is closed: nothing of the first session is left but the files.
        final closed = first.backend.close();
        gate.complete();
        await closed;
        await pumpEventQueue();
        final onDisk = files.bytesOf(part)!.length;
        expect(onDisk, anyOf(200, 300));
        server.beforeChunk = null;
        expect(running, isA<Future<void>>());

        final c = make();
        expect(c.now, const Absent());
        await c.start(request(bytes: 450, sha256: sha256Of(body)));
        expect(server.requests.last['range'], 'bytes=$onDisk-');
        expect(c.now, const Complete(loc, 450));
        expect(files.bytesOf(dest), body);
      },
    );

    test(
      'closing the backend aborts the request and reports nothing more',
      () async {
        server.beforeChunk = (i) =>
            i == 1 ? Completer<void>().future : Future<void>.value();
        final c = make();
        unawaited(c.start(request()));
        await pumpEventQueue();
        final before = c.history.length;
        await c.backend.close();
        expect(files.bytesOf(part), body.sublist(0, 100));
        expect(c.history, hasLength(before));
      },
    );
  });

  group('cancel', () {
    test('during a download stops it and deletes what it kept', () async {
      final gate = Completer<void>();
      server.beforeChunk = (i) => i == 1 ? gate.future : Future<void>.value();
      final c = make();
      final packs = c;
      final done = packs.start(request());
      await pumpEventQueue();
      expect(files.bytesOf(part), isNotNull);
      final removed = packs.remove('douala');
      gate.complete();
      await removed;
      await done;
      expect(
        files.paths,
        isEmpty,
        reason: 'the transfer closed its file before it was deleted',
      );
      expect(c.now, const Absent());
    });

    test('a paused download loses its partial file', () async {
      final gate = Completer<void>();
      server.beforeChunk = (i) => i == 1 ? gate.future : Future<void>.value();
      final c = make();
      final done = c.start(request());
      await pumpEventQueue();
      final paused = c.pause('douala');
      gate.complete();
      await paused;
      await done;
      expect(files.bytesOf(part), isNotNull);
      await c.backend.cancel('douala');
      expect(files.paths, isEmpty);
    });

    test(
      'a transfer that ended keeps its partial file, so retry can continue it',
      () async {
        server.breakAfter = 200;
        final c = make();
        await c.start(request(bytes: 450));
        expect(c.now, const Failed(DownloadFailure.network));
        await c.backend.cancel('douala');
        expect(files.bytesOf(part), body.sublist(0, 200));
      },
    );

    test(
      'cancelAll stops every transfer and deletes every partial file',
      () async {
        server.beforeChunk = (i) =>
            i == 1 ? Completer<void>().future : Future<void>.value();
        final c = make();
        unawaited(c.start(request()));
        unawaited(c.start(request(id: 'b', path: 'b.pmtiles')));
        await pumpEventQueue();
        expect(files.bytesOf('$root/b.pmtiles.part'), isNotNull);
        await c.backend.cancelAll();
        expect(files.paths, isEmpty);
      },
    );

    test('a start during a cancel takes the id over', () async {
      final gate = Completer<void>();
      server.beforeChunk = (i) => i == 1 ? gate.future : Future<void>.value();
      final c = make();
      final packs = c;
      final first = packs.start(request());
      await pumpEventQueue();
      final removed = packs.remove('douala');
      gate.complete();
      server.beforeChunk = null;
      final second = packs.start(request());
      await Future.wait([removed, first, second]);
      expect(c.now, isA<Complete>());
      expect(files.bytesOf(dest), body);
    });
  });

  group('a changed file is never spliced onto an old partial', () {
    test(
      'a 206 from a server that ignores If-Range, with a new ETag, restarts',
      () async {
        server.ignoreIfRange = true;
        files.putBytes(part, List<int>.filled(120, 9));
        files.putText(tag, '"old"');
        final c = make();
        await c.start(request(bytes: 450));
        expect(server.requests.map((r) => r['range']), ['bytes=120-', null]);
        expect(files.bytesOf(dest), body);
        expect(files.textOf(tag), isNull);
      },
    );

    test('a 206 with the same validator is continued', () async {
      server.ignoreIfRange = true;
      files.putBytes(part, body.sublist(0, 120));
      files.putText(tag, '"v1"');
      final c = make();
      await c.start(request(bytes: 450));
      expect(server.requests.map((r) => r['range']), ['bytes=120-']);
      expect(files.bytesOf(dest), body);
    });

    test(
      'no validator and no hash: the file may have changed, so it starts from 0',
      () async {
        files.putBytes(part, List<int>.filled(120, 9));
        final c = make();
        await c.start(request(bytes: 450));
        expect(server.requests.single.containsKey('range'), isFalse);
        expect(server.requests.single.containsKey('if-range'), isFalse);
        expect(files.bytesOf(dest), body);
      },
    );

    test(
      'no validator but a hash: the continuation is checked at the end',
      () async {
        files.putBytes(part, body.sublist(0, 120));
        final c = make();
        await c.start(request(sha256: sha256Of(body)));
        expect(server.requests.single['range'], 'bytes=120-');
        expect(files.bytesOf(dest), body);
      },
    );

    test('a spliced file the hash catches is deleted', () async {
      files.putBytes(part, List<int>.filled(120, 9));
      final c = make();
      await c.start(request(sha256: sha256Of(body)));
      expect(c.now, const Failed(DownloadFailure.hashMismatch));
      expect(files.paths, isEmpty);
    });

    test('the old validator is gone before a new file starts', () async {
      files.putBytes(part, body.sublist(0, 50));
      files.putText(tag, '"old"');
      server.honourRange = false;
      server.etag = null;
      final c = make();
      await c.start(request(bytes: 450));
      expect(files.bytesOf(dest), body);
      expect(files.textOf(tag), isNull);
    });
  });

  group('a connection that sends nothing cannot hold the pack', () {
    test('pause and resume while a chunk never comes', () async {
      server.beforeChunk = (i) =>
          i == 1 ? Completer<void>().future : Future<void>.value();
      final c = make();
      final packs = c;
      final done = packs.start(request(bytes: 450));
      await pumpEventQueue();
      await packs.pause('douala');
      await done;
      expect(c.now, isA<Paused>());
      expect(files.bytesOf(part), body.sublist(0, 100));
      server.beforeChunk = null;
      await packs.resume('douala');
      expect(c.now, const Complete(loc, 450));
    });

    test('remove while a chunk never comes, and a start after it', () async {
      server.beforeChunk = (i) =>
          i == 1 ? Completer<void>().future : Future<void>.value();
      final c = make();
      final packs = c;
      final done = packs.start(request());
      await pumpEventQueue();
      await packs.remove('douala');
      await done;
      expect(files.paths, isEmpty);
      server.beforeChunk = null;
      await packs.start(request());
      expect(c.now, isA<Complete>());
    });

    test('remove while the server never answers', () async {
      server.hold = Completer<void>().future;
      final c = make();
      final packs = c;
      final done = packs.start(request());
      await pumpEventQueue();
      await packs.remove('douala');
      await done;
      expect(c.now, const Absent());
    });

    for (final yields in [0, 1, 2, 3, 5, 8]) {
      test(
        'remove then start during the transfer\'s own awaits ($yields)',
        () async {
          files.putBytes(part, body.sublist(0, 100));
          files.putText(tag, '"v1"');
          server.hold = Completer<void>().future;
          final c = make();
          final packs = c;
          final first = packs.start(request());
          for (var i = 0; i < yields; i++) {
            await Future<void>.value();
          }
          final removed = packs.remove('douala');
          final second = packs.start(request());
          await removed;
          await first;
          await packs.remove('douala');
          await second;
          expect(c.statuses, isEmpty);
          expect(files.paths, isEmpty);
        },
      );
    }
  });

  group('a body nobody reads is cancelled', () {
    for (final code in [404, 500]) {
      test('a $code error page', () async {
        server.forceStatus = code;
        server.forceBody = sampleBody(300);
        final c = make();
        await c.start(request());
        await pumpEventQueue();
        expect(server.cancelled, 1);
      });
    }

    test('a 416 that restarts, and a 206 at another offset', () async {
      files.putBytes(part, List<int>.filled(900, 1));
      final c = make();
      await c.start(request(sha256: sha256Of(body)));
      expect(files.bytesOf(dest), body);
      expect(
        server.cancelled,
        0,
        reason: 'the 416 had no body; the restart read all of its',
      );
    });

    test('a size mismatch announced before the bytes', () async {
      final c = make();
      await c.start(request(bytes: 300));
      await pumpEventQueue();
      expect(server.cancelled, 1);
    });
  });

  test(
    'a start over a file of another size keeps it until the new one is whole',
    () async {
      files.putBytes(dest, [1, 2, 3]);
      final gate = Completer<void>();
      server.beforeChunk = (i) => i == 1 ? gate.future : Future<void>.value();
      final c = make();
      final done = c.start(request(bytes: 450));
      await pumpEventQueue();
      expect(files.bytesOf(dest), [1, 2, 3]);
      gate.complete();
      await done;
      expect(files.bytesOf(dest), body);
    },
  );

  group('the dart:io store', () {
    late Directory dir;
    setUp(
      () => dir = Directory.systemTemp.createTempSync('fespalier_download'),
    );
    tearDown(() => dir.deleteSync(recursive: true));

    Rig onDisk() => Rig(
      server.client,
      defaultTransferFiles(),
      basesOf: (_) async => dir.path,
    );

    test('downloads, resumes and verifies on a real disk', () async {
      final path = '${dir.path}/nested/dir/douala.pmtiles';
      final c = onDisk();
      server.breakAfter = 300;
      final r = request(
        path: 'nested/dir/douala.pmtiles',
        bytes: 450,
        sha256: sha256Of(body),
      );
      await c.start(r);
      expect(c.now, const Failed(DownloadFailure.network));
      expect(File('$path.part').lengthSync(), 300);
      expect(File(path).existsSync(), isFalse);
      await c.retry('douala');
      expect(server.requests.last['range'], 'bytes=300-');
      expect(c.now, Complete(r.file, 450));
      expect(File(path).readAsBytesSync(), body);
      expect(File('$path.part').existsSync(), isFalse);
      expect(File('$path.part.etag').existsSync(), isFalse);
      await c.engineFiles.delete(r.file);
      expect(File(path).existsSync(), isFalse);
    });

    test('a hash mismatch deletes the partial file on disk', () async {
      final c = onDisk();
      await c.start(request(path: 'a.pmtiles', sha256: '1' * 64));
      expect(c.now, const Failed(DownloadFailure.hashMismatch));
      expect(dir.listSync(), isEmpty);
    });

    test(
      'TransferDownloadFiles sees, measures and deletes a download',
      () async {
        final c = onDisk();
        final files = c.engineFiles;
        const where = DownloadLocation(DownloadBase.support, 'x/y.bin');
        expect(await files.exists(where), isFalse);
        expect(await files.length(where), isNull);
        File('${dir.path}/x/y.bin.part').createSync(recursive: true);
        File('${dir.path}/x/y.bin.part.etag').writeAsStringSync('"v"');
        File('${dir.path}/x/y.bin').writeAsBytesSync([1, 2, 3]);
        expect(await files.exists(where), isTrue);
        expect(await files.length(where), 3);
        await files.delete(where);
        expect(Directory('${dir.path}/x').listSync(), isEmpty);
        await files.delete(where);
      },
    );
  });

  test(
    'on the web (no dart:io) every download ends unsupported, before a request',
    () async {
      final c = make(store: FakeTransferFiles()..unsupported = true);
      await c.start(request());
      expect(c.now, const Failed(DownloadFailure.unsupported));
      expect(server.requests, isEmpty);
      final downloads = TransferDownloadFiles(
        bases: defaultBases,
        files: FakeTransferFiles()..unsupported = true,
      );
      expect(await downloads.exists(loc), isFalse);
      await downloads.delete(loc);
    },
  );

  group('the backend', () {
    test('says what it can do, and no more', () {
      final caps = make().backend.capabilities;
      expect(caps.pause, isTrue);
      expect(caps.background, isFalse);
      expect(caps.notifications, isFalse);
      expect(caps.unmetered, isFalse);
      expect(caps.userInitiated, isFalse);
      expect(caps.resumeAcrossRestart, isFalse);
    });

    test('resolves a location under the folder of its base', () async {
      final c = make();
      expect(await c.backend.resolve(loc), dest);
      final trailing = HttpDownloadBackend(
        client: server.client,
        bases: (_) async => '/packs/',
        files: files,
      );
      expect(await trailing.resolve(loc), dest);
      await expectLater(
        c.backend.resolve(const DownloadLocation(DownloadBase.support, '../x')),
        throwsArgumentError,
      );
    });

    test(
      'adds the authorization to this attempt only, over the request headers',
      () async {
        final gate = Completer<void>();
        server.beforeChunk = (i) => i == 1 ? gate.future : Future<void>.value();
        final c = make();
        final r = request(headers: const {'x-a': '1', 'x-b': '2'});
        c.history.clear();
        unawaited(c.start(r));
        // start() passes none: use the backend directly for the authorization.
        await pumpEventQueue();
        await c.pause('douala');
        gate.complete();
        server.beforeChunk = null;
        await c.resume(
          'douala',
          authorization: const {'x-b': 'fresh', 'x-c': '3'},
        );
        expect(server.requests.last['x-a'], '1');
        expect(server.requests.last['x-b'], 'fresh');
        expect(server.requests.last['x-c'], '3');
        expect(server.requests.first.containsKey('x-c'), isFalse);
      },
    );

    test('reports Verifying between the last byte and Complete', () async {
      final c = make();
      await c.start(request(bytes: 450, sha256: sha256Of(body)));
      final kinds = [for (final (_, s) in c.history) s.runtimeType];
      expect(kinds.indexOf(Verifying), greaterThan(kinds.indexOf(Running)));
      expect(kinds.last, Complete);
    });

    test('an id that is running is not started twice', () async {
      final gate = Completer<void>();
      server.beforeChunk = (i) => i == 1 ? gate.future : Future<void>.value();
      final c = make();
      final done = c.start(request());
      await pumpEventQueue();
      expect(await c.backend.enqueue(request()), isTrue);
      gate.complete();
      await done;
      expect(server.requests, hasLength(1));
    });

    test('nothing it reports prints a path or a URL', () async {
      final c = make();
      await c.start(request(bytes: 449));
      for (final (_, s) in c.history) {
        expect(s.toString(), isNot(contains('douala')));
        expect(s.toString(), isNot(contains('/')));
      }
    });
  });
}

/// A client that answers with [answer] when it returns a response, and otherwise lets [inner]
/// (a `FileServer`'s client) answer.
class _Switch extends http.BaseClient {
  _Switch(this.answer, this.server);

  final http.StreamedResponse? Function(http.BaseRequest request)? answer;
  final FileServer server;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final own = answer?.call(request);
    if (own != null) {
      server.requests.add({...request.headers});
      return own;
    }
    return server.client.send(request);
  }
}
