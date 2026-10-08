// File packs against a fake server and in-memory files: a whole download, a resume with Range
// from a partial file, a server that ignores Range, checks that fail, refusals, pause and resume,
// a restart whose state is rebuilt from disk, removal in the middle, and the real dart:io store.
import 'dart:async';
import 'dart:io';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_maps/fespalier_maps.dart';
import 'package:fespalier_maps/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'pack_server.dart';

const dest = '/packs/douala.pmtiles';
const part = '$dest.part';
const tag = '$part.etag';

void main() {
  final body = sampleBody(450);
  late PackServer server;
  late FakePackFiles files;

  FilePackRequest request({
    String key = 'douala',
    String path = dest,
    int? bytes,
    String? sha256,
    Map<String, String> headers = const {},
  }) => FilePackRequest(
    key: key,
    url: Uri.parse('https://tiles.example.com/douala.pmtiles'),
    destination: path,
    bytes: bytes,
    sha256: sha256,
    headers: headers,
  );

  ProviderContainer make({http.Client? client, PackFileStore? store}) {
    final c = ProviderContainer(
      overrides: [
        packHttpClient.overrideWithValue(client ?? server.client),
        packFileStore.overrideWithValue(store ?? files),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  setUp(() {
    server = PackServer(body);
    files = FakePackFiles();
  });

  group('a whole download', () {
    test(
      'arrives in .part and is moved to the destination when whole',
      () async {
        final c = make();
        final packs = c.read(filePacks.notifier);
        final seen = <PackStatus>[];
        c.listen(filePackStatus('douala'), (_, s) => seen.add(s));
        await packs.start(request(bytes: 450, sha256: sha256Of(body)));
        expect(c.read(filePackStatus('douala')), const Complete(bytes: 450));
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
        expect(seen.last, isA<Complete>());
      },
    );
  });

  group('resume with Range', () {
    test('a partial file is continued from its size, with If-Range', () async {
      files.putBytes(part, body.sublist(0, 120));
      files.putText(tag, '"v1"');
      final c = make();
      await c
          .read(filePacks.notifier)
          .start(request(bytes: 450, sha256: sha256Of(body)));
      expect(server.requests.single['range'], 'bytes=120-');
      expect(server.requests.single['if-range'], '"v1"');
      expect(c.read(filePackStatus('douala')), const Complete(bytes: 450));
      expect(files.bytesOf(dest), body, reason: 'appended at the right offset');
    });

    test('the first progress report starts at the partial size', () async {
      files.putBytes(part, body.sublist(0, 225));
      final gate = Completer<void>();
      server.beforeChunk = (i) => gate.future;
      final c = make();
      final done = c.read(filePacks.notifier).start(request(bytes: 450));
      await pumpEventQueue();
      expect(
        c.read(filePackStatus('douala')),
        const Downloading(progress: 0.5, bytes: 225),
      );
      gate.complete();
      await done;
    });

    test(
      'a server that ignores Range sends the whole body, and the transfer restarts at 0',
      () async {
        server.honourRange = false;
        files.putBytes(part, body.sublist(0, 120));
        final c = make();
        await c
            .read(filePacks.notifier)
            .start(request(bytes: 450, sha256: sha256Of(body)));
        expect(server.requests.single['range'], 'bytes=120-');
        expect(c.read(filePackStatus('douala')), const Complete(bytes: 450));
        expect(files.bytesOf(dest), body, reason: 'not 120 bytes twice');
      },
    );

    test(
      'a file that changed on the server (If-Range does not match) is fetched whole',
      () async {
        files.putBytes(part, List<int>.filled(120, 9));
        files.putText(tag, '"old"');
        final c = make();
        await c
            .read(filePacks.notifier)
            .start(request(bytes: 450, sha256: sha256Of(body)));
        expect(server.requests.single['if-range'], '"old"');
        expect(files.bytesOf(dest), body);
        expect(c.read(filePackStatus('douala')), isA<Complete>());
      },
    );

    test('a partial file already whole skips the network', () async {
      files.putBytes(part, body);
      final c = make();
      await c
          .read(filePacks.notifier)
          .start(request(bytes: 450, sha256: sha256Of(body)));
      expect(server.requests, isEmpty);
      expect(files.bytesOf(dest), body);
    });

    test(
      'a partial file longer than the file is dropped before asking',
      () async {
        files.putBytes(part, List<int>.filled(900, 1));
        final c = make();
        await c.read(filePacks.notifier).start(request(bytes: 450));
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
        await c.read(filePacks.notifier).start(request());
        expect(server.requests.map((r) => r['range']), ['bytes=900-', null]);
        expect(files.bytesOf(dest), body);
      },
    );

    test(
      'a 416 that says the partial file is the whole file finishes it',
      () async {
        files.putBytes(part, body);
        final c = make();
        await c.read(filePacks.notifier).start(request(sha256: sha256Of(body)));
        expect(server.requests.single['range'], 'bytes=450-');
        expect(files.bytesOf(dest), body);
        expect(c.read(filePackStatus('douala')), const Complete(bytes: 450));
      },
    );

    test('a 416 on a fresh download is a refusal', () async {
      server.forceStatus = 416;
      final c = make();
      await c.read(filePacks.notifier).start(request());
      expect(
        c.read(filePackStatus('douala')),
        const Failed(PackFailure.rejected),
      );
    });

    test('a 416 that survives the restart is a refusal, not a loop', () async {
      files.putBytes(part, body.sublist(0, 10));
      server.forceStatus = 416;
      final c = make();
      await c.read(filePacks.notifier).start(request());
      expect(
        c.read(filePackStatus('douala')),
        const Failed(PackFailure.rejected),
      );
      expect(server.requests, hasLength(2));
    });

    test(
      'a 206 that starts somewhere else than asked restarts from 0',
      () async {
        files.putBytes(part, body.sublist(0, 100));
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
        await c.read(filePacks.notifier).start(request(bytes: 450));
        expect(files.bytesOf(dest), body);
      },
    );
  });

  group('checks', () {
    test(
      'a size that is not the request\'s fails and deletes the partial file',
      () async {
        final c = make();
        await c.read(filePacks.notifier).start(request(bytes: 449));
        expect(
          c.read(filePackStatus('douala')),
          const Failed(PackFailure.sizeMismatch),
        );
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
        await c.read(filePacks.notifier).start(request(bytes: 300));
        expect(
          c.read(filePackStatus('douala')),
          const Failed(PackFailure.sizeMismatch),
        );
        expect(files.paths, isEmpty);
      },
    );

    test(
      'a hash that does not match fails, deletes the file, and moves nothing',
      () async {
        final c = make();
        await c
            .read(filePacks.notifier)
            .start(request(bytes: 450, sha256: '0' * 64));
        expect(
          c.read(filePackStatus('douala')),
          const Failed(PackFailure.hashMismatch),
        );
        expect(files.paths, isEmpty);
        expect(files.renames, isEmpty);
      },
    );

    test('the hash may be written in capitals', () async {
      final c = make();
      await c
          .read(filePacks.notifier)
          .start(request(sha256: sha256Of(body).toUpperCase()));
      expect(c.read(filePackStatus('douala')), isA<Complete>());
    });

    test('a retry after a hash mismatch starts clean, without Range', () async {
      final c = make();
      final packs = c.read(filePacks.notifier);
      await packs.start(request(sha256: '0' * 64));
      await packs.resume('douala');
      expect(server.requests.map((r) => r['range']), [null, null]);
    });

    test(
      'the server announcing another size than the request names fails before the bytes',
      () async {
        final c = make();
        await c.read(filePacks.notifier).start(request(bytes: 300));
        expect(
          c.read(filePackStatus('douala')),
          const Failed(PackFailure.sizeMismatch),
        );
        expect(files.bytesOf(part), isNull);
      },
    );
  });

  group('refusals and failures', () {
    for (final code in [404, 403, 500, 503]) {
      test('a $code is Failed(rejected) and keeps the partial file', () async {
        files.putBytes(part, body.sublist(0, 100));
        server.forceStatus = code;
        final c = make();
        await c.read(filePacks.notifier).start(request());
        expect(
          c.read(filePackStatus('douala')),
          const Failed(PackFailure.rejected),
        );
        expect(files.bytesOf(part), body.sublist(0, 100));
      });
    }

    test('no connection is Failed(network)', () async {
      server.connectError = http.ClientException('no route');
      final c = make();
      await c.read(filePacks.notifier).start(request());
      expect(
        c.read(filePackStatus('douala')),
        const Failed(PackFailure.network),
      );
    });

    test(
      'a connection that breaks keeps what arrived, and resume goes on from it',
      () async {
        server.breakAfter = 200;
        final c = make();
        final packs = c.read(filePacks.notifier);
        await packs.start(request(bytes: 450, sha256: sha256Of(body)));
        expect(
          c.read(filePackStatus('douala')),
          const Failed(PackFailure.network),
        );
        expect(files.bytesOf(part), body.sublist(0, 200));
        await packs.resume('douala');
        expect(server.requests.last['range'], 'bytes=200-');
        expect(c.read(filePackStatus('douala')), const Complete(bytes: 450));
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
        await c.read(filePacks.notifier).start(request());
        expect(
          c.read(filePackStatus('douala')),
          const Failed(PackFailure.network),
        );
        expect(files.bytesOf(part), body.sublist(0, 200));
      },
    );

    test('a write the device refuses is Failed(storage)', () async {
      files.failWrites = const FileSystemException('No space left on device');
      final c = make();
      await c.read(filePacks.notifier).start(request());
      expect(
        c.read(filePackStatus('douala')),
        const Failed(PackFailure.storage),
      );
    });

    test(
      'a move that fails is Failed(storage) and the partial file stays whole',
      () async {
        files.failRename = const FileSystemException('denied');
        final c = make();
        await c.read(filePacks.notifier).start(request());
        expect(
          c.read(filePackStatus('douala')),
          const Failed(PackFailure.storage),
        );
        expect(files.bytesOf(part), body);
      },
    );

    test(
      'where there are no files (the web) it fails before any request',
      () async {
        files.unsupported = true;
        final c = make();
        await c.read(filePacks.notifier).start(request());
        expect(
          c.read(filePackStatus('douala')),
          const Failed(PackFailure.unsupported),
        );
        expect(server.requests, isEmpty);
      },
    );

    test(
      'an invalid request reaches neither the disk nor the network',
      () async {
        final c = make();
        final packs = c.read(filePacks.notifier);
        for (final bad in [
          request(key: 'a', sha256: 'xyz'),
          request(key: 'a', bytes: 0),
          request(key: 'a', path: ''),
          FilePackRequest(
            key: 'a',
            url: Uri.parse('ftp://x/y'),
            destination: dest,
          ),
          FilePackRequest(
            key: 'a',
            url: Uri.parse('/relative'),
            destination: dest,
          ),
        ]) {
          expect(bad.isValid, isFalse);
          await packs.start(bad);
          expect(
            c.read(filePackStatus('a')),
            const Failed(PackFailure.invalidRequest),
          );
        }
        await packs.start(request(key: ''));
        expect(c.read(filePacks), {
          'a': const Failed(PackFailure.invalidRequest),
        });
        expect(server.requests, isEmpty);
        expect(files.paths, isEmpty);
      },
    );

    test('two keys cannot share a destination', () async {
      final c = make();
      final packs = c.read(filePacks.notifier);
      await packs.start(request());
      await packs.start(request(key: 'other'));
      expect(
        c.read(filePackStatus('other')),
        const Failed(PackFailure.invalidRequest),
      );
      expect(c.read(filePackStatus('douala')), isA<Complete>());
    });

    test(
      'a client that was not provided is a loud error, not a silent failure',
      () async {
        final c = ProviderContainer(
          overrides: [packFileStore.overrideWithValue(files)],
        );
        addTearDown(c.dispose);
        await expectLater(
          c.read(filePacks.notifier).start(request()),
          throwsA(isA<Object>()),
        );
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
        final packs = c.read(filePacks.notifier);
        final done = packs.start(request(bytes: 450, sha256: sha256Of(body)));
        await pumpEventQueue();
        expect(c.read(filePackStatus('douala')), isA<Downloading>());
        final paused = packs.pause('douala');
        gate.complete();
        await paused;
        await done;
        final status = c.read(filePackStatus('douala')) as Paused;
        expect(status.bytes, 200);
        expect(status.progress, closeTo(200 / 450, 1e-9));
        expect(files.bytesOf(part), body.sublist(0, 200));
        expect(files.bytesOf(dest), isNull);
        server.beforeChunk = null;
        await packs.resume('douala');
        expect(server.requests.last['range'], 'bytes=200-');
        expect(c.read(filePackStatus('douala')), const Complete(bytes: 450));
        expect(files.bytesOf(dest), body);
      },
    );

    test('start of a paused pack does nothing: resume is the verb', () async {
      final gate = Completer<void>();
      server.beforeChunk = (i) => i == 1 ? gate.future : Future<void>.value();
      final c = make();
      final packs = c.read(filePacks.notifier);
      final done = packs.start(request());
      await pumpEventQueue();
      final paused = packs.pause('douala');
      gate.complete();
      await paused;
      await done;
      final before = server.requests.length;
      await packs.start(request());
      expect(server.requests, hasLength(before));
      expect(c.read(filePackStatus('douala')), isA<Paused>());
    });

    test('pause and resume of what is not running do nothing', () async {
      final c = make();
      final packs = c.read(filePacks.notifier);
      await packs.pause('nothing');
      await packs.resume('nothing');
      await packs.start(request());
      await packs.pause('douala');
      await packs.resume('douala');
      expect(c.read(filePackStatus('douala')), isA<Complete>());
      expect(server.requests, hasLength(1));
    });

    test(
      'a pause asked while the request is in flight pauses before the first byte',
      () async {
        final answer = Completer<void>();
        final c = make(client: _Switch(null, server, hold: answer.future));
        final packs = c.read(filePacks.notifier);
        final done = packs.start(request());
        await pumpEventQueue();
        final paused = packs.pause('douala');
        answer.complete();
        await paused;
        await done;
        expect(c.read(filePackStatus('douala')), const Paused());
        expect(files.bytesOf(part), isNull);
      },
    );
  });

  group('a restart', () {
    test(
      'the state is rebuilt from disk and the transfer continues with Range',
      () async {
        final gate = Completer<void>();
        server.beforeChunk = (i) => i == 2 ? gate.future : Future<void>.value();
        final first = ProviderContainer(
          overrides: [
            packHttpClient.overrideWithValue(server.client),
            packFileStore.overrideWithValue(files),
          ],
        );
        final running = first
            .read(filePacks.notifier)
            .start(request(bytes: 450));
        await pumpEventQueue();
        expect(files.bytesOf(part), body.sublist(0, 200));
        // The app is closed: nothing of the first session is left but the files.
        first.dispose();
        gate.complete();
        await running;
        await pumpEventQueue();
        final onDisk = files.bytesOf(part)!.length;
        expect(onDisk, anyOf(200, 300));
        server.beforeChunk = null;

        final c = make();
        final packs = c.read(filePacks.notifier);
        expect(c.read(filePackStatus('douala')), const Absent());
        await packs.refresh([request(bytes: 450, sha256: sha256Of(body))]);
        expect(
          c.read(filePackStatus('douala')),
          Interrupted(progress: onDisk / 450, bytes: onDisk),
        );
        await packs.resume('douala');
        expect(server.requests.last['range'], 'bytes=$onDisk-');
        expect(c.read(filePackStatus('douala')), const Complete(bytes: 450));
        expect(files.bytesOf(dest), body);
      },
    );

    test('refresh finds a complete file, a partial one, and nothing', () async {
      files.putBytes(dest, body);
      files.putBytes('/packs/b.pmtiles.part', List<int>.filled(45, 1));
      final c = make();
      final packs = c.read(filePacks.notifier);
      await packs.refresh([
        request(bytes: 450),
        request(key: 'b', path: '/packs/b.pmtiles', bytes: 450),
        request(key: 'c', path: '/packs/c.pmtiles'),
        request(key: 'bad', bytes: -1),
      ]);
      expect(c.read(filePacks), {
        'douala': const Complete(bytes: 450),
        'b': const Interrupted(progress: 0.1, bytes: 45),
      });
    });

    test(
      'refresh leaves a running download alone, and drops a pack whose files are gone',
      () async {
        final gate = Completer<void>();
        server.beforeChunk = (i) => i == 1 ? gate.future : Future<void>.value();
        final c = make();
        final packs = c.read(filePacks.notifier);
        final done = packs.start(request());
        await pumpEventQueue();
        await packs.refresh([request()]);
        expect(c.read(filePackStatus('douala')), isA<Downloading>());
        gate.complete();
        await done;
        files
          ..putBytes(dest, const [])
          ..bytesOf(dest);
        await files.delete(dest);
        await packs.refresh([request()]);
        expect(c.read(filePackStatus('douala')), const Absent());
      },
    );

    test('refresh on the web marks the pack unsupported', () async {
      files.unsupported = true;
      final c = make();
      await c.read(filePacks.notifier).refresh([request()]);
      expect(
        c.read(filePackStatus('douala')),
        const Failed(PackFailure.unsupported),
      );
    });
  });

  group('remove', () {
    test('during a download stops it and deletes every file', () async {
      final gate = Completer<void>();
      server.beforeChunk = (i) => i == 1 ? gate.future : Future<void>.value();
      final c = make();
      final packs = c.read(filePacks.notifier);
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
      expect(c.read(filePackStatus('douala')), const Absent());
      expect(c.read(filePacks), isEmpty);
    });

    test(
      'a finished pack, and a partial one of an earlier session after refresh',
      () async {
        files.putBytes(dest, body);
        files.putBytes('/p/x.part', [1]);
        files.putText('/p/x.part.etag', '"v"');
        final c = make();
        final packs = c.read(filePacks.notifier);
        await packs.refresh([request(), request(key: 'x', path: '/p/x')]);
        await packs.remove('douala');
        await packs.remove('x');
        expect(files.paths, isEmpty);
        expect(c.read(filePacks), isEmpty);
      },
    );

    test('a file that cannot be deleted fails the pack and throws', () async {
      final c = make();
      final packs = c.read(filePacks.notifier);
      await packs.start(request());
      files.failDelete = const FileSystemException('busy');
      await expectLater(
        packs.remove('douala'),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        c.read(filePackStatus('douala')),
        const Failed(PackFailure.storage),
      );
    });

    test('a start during a remove takes the key over', () async {
      final gate = Completer<void>();
      server.beforeChunk = (i) => i == 1 ? gate.future : Future<void>.value();
      final c = make();
      final packs = c.read(filePacks.notifier);
      final first = packs.start(request());
      await pumpEventQueue();
      final removed = packs.remove('douala');
      gate.complete();
      server.beforeChunk = null;
      final second = packs.start(request());
      await Future.wait([removed, first, second]);
      expect(c.read(filePackStatus('douala')), isA<Complete>());
      expect(files.bytesOf(dest), body);
    });
  });

  group('storage', () {
    test(
      'per pack from the state, and the files on disk as their sum',
      () async {
        files.putBytes('/packs/b.pmtiles.part', List<int>.filled(45, 1));
        final c = make();
        final packs = c.read(filePacks.notifier);
        await packs.start(request());
        await packs.refresh([request(key: 'b', path: '/packs/b.pmtiles')]);
        final use = await packs.storage();
        expect(use.perPack, {'douala': 450, 'b': 45});
        expect(use.packSum, 495);
        expect(use.onDisk, 495);
      },
    );

    test('no files, no size', () async {
      final c = make();
      final packs = c.read(filePacks.notifier);
      await packs.start(request());
      files.unsupported = true;
      expect((await packs.storage()).onDisk, isNull);
    });
  });

  test('the request prints no field', () {
    expect(request().toString(), 'FilePackRequest');
    expect(request(), request());
    expect(request().hashCode, request().hashCode);
    expect(request(bytes: 1), isNot(request()));
  });

  test('pmtilesSourceUrl is the pmtiles:// form of the file URL', () {
    expect(
      pmtilesSourceUrl('/data/user/0/app/files/packs/douala.pmtiles'),
      'pmtiles://file:///data/user/0/app/files/packs/douala.pmtiles',
    );
    expect(
      pmtilesSourceUrl('/var/My Maps/a b.pmtiles'),
      'pmtiles://file:///var/My%20Maps/a%20b.pmtiles',
    );
  });

  group('the dart:io store', () {
    late Directory dir;
    setUp(
      () => dir = Directory.systemTemp.createTempSync('fespalier_maps_files'),
    );
    tearDown(() => dir.deleteSync(recursive: true));

    test('downloads, resumes and verifies on a real disk', () async {
      final path = '${dir.path}/nested/dir/douala.pmtiles';
      // The default store is the dart:io one: only the client is overridden.
      final c = ProviderContainer(
        overrides: [packHttpClient.overrideWithValue(server.client)],
      );
      addTearDown(c.dispose);
      final packs = c.read(filePacks.notifier);
      server.breakAfter = 300;
      final r = request(path: path, bytes: 450, sha256: sha256Of(body));
      await packs.start(r);
      expect(
        c.read(filePackStatus('douala')),
        const Failed(PackFailure.network),
      );
      expect(File('$path.part').lengthSync(), 300);
      expect(File(path).existsSync(), isFalse);
      await packs.resume('douala');
      expect(server.requests.last['range'], 'bytes=300-');
      expect(c.read(filePackStatus('douala')), const Complete(bytes: 450));
      expect(File(path).readAsBytesSync(), body);
      expect(File('$path.part').existsSync(), isFalse);
      expect(File('$path.part.etag').existsSync(), isFalse);
      await packs.remove('douala');
      expect(File(path).existsSync(), isFalse);
    });

    test('a hash mismatch deletes the partial file on disk', () async {
      final path = '${dir.path}/a.pmtiles';
      final c = ProviderContainer(
        overrides: [packHttpClient.overrideWithValue(server.client)],
      );
      addTearDown(c.dispose);
      await c
          .read(filePacks.notifier)
          .start(request(path: path, sha256: '1' * 64));
      expect(
        c.read(filePackStatus('douala')),
        const Failed(PackFailure.hashMismatch),
      );
      expect(dir.listSync(), isEmpty);
    });
  });
}

/// A client that answers with [answer] when it returns a response, and otherwise lets [inner]
/// (a `PackServer`'s client) answer; [hold] delays the answer.
class _Switch extends http.BaseClient {
  _Switch(this.answer, this.server, {this.hold});

  final http.StreamedResponse? Function(http.BaseRequest request)? answer;
  final PackServer server;
  final Future<void>? hold;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await hold;
    final own = answer?.call(request);
    if (own != null) {
      server.requests.add({...request.headers});
      return own;
    }
    return server.client.send(request);
  }
}
