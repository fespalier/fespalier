import 'dart:convert';
import 'dart:io';

import 'package:fespalier/src/launcher.dart';
import 'package:fespalier/src/release_checksums.dart' as pinned;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('target detection', () {
    test('maps every published platform', () {
      expect(fspTarget('linux_x64'), 'x86_64-unknown-linux-gnu');
      expect(fspTarget('linux_arm64'), 'aarch64-unknown-linux-gnu');
      expect(fspTarget('macos_x64'), 'x86_64-apple-darwin');
      expect(fspTarget('macos_arm64'), 'aarch64-apple-darwin');
      expect(fspTarget('windows_x64'), 'x86_64-pc-windows-msvc');
      expect(fspTarget('windows_arm64'), 'x86_64-pc-windows-msvc');
    });

    test('is null where nothing is published', () {
      expect(fspTarget('linux_riscv64'), isNull);
      expect(fspTarget('android_arm64'), isNull);
      expect(fspTarget('ios_arm64'), isNull);
    });

    test('names archives and binaries like the release workflow', () {
      expect(
        archiveName('x86_64-unknown-linux-gnu'),
        'fsp-x86_64-unknown-linux-gnu.tar.gz',
      );
      expect(
        archiveName('aarch64-apple-darwin'),
        'fsp-aarch64-apple-darwin.tar.gz',
      );
      expect(
        archiveName('x86_64-pc-windows-msvc'),
        'fsp-x86_64-pc-windows-msvc.zip',
      );
      expect(binaryName('x86_64-pc-windows-msvc'), 'fsp.exe');
      expect(binaryName('aarch64-apple-darwin'), 'fsp');
    });

    test('builds release URLs', () {
      expect(
        releaseUrl(
          defaultBaseUrl,
          '0.1.1',
          'fsp-x86_64-apple-darwin.tar.gz.sha256',
        ).toString(),
        'https://github.com/vaam-apps/fespalier/releases/download/v0.1.1/fsp-x86_64-apple-darwin.tar.gz.sha256',
      );
      expect(
        releaseUrl('http://localhost:8/', '1.0.0', 'a').toString(),
        'http://localhost:8/v1.0.0/a',
      );
    });
  });

  group('parsing', () {
    test('pubspec version', () {
      expect(
        parsePubspecVersion('name: x\nversion: 0.1.1\nhomepage: y'),
        '0.1.1',
      );
      expect(
        parsePubspecVersion('version: "1.2.3-dev.1" # note'),
        '1.2.3-dev.1',
      );
      expect(parsePubspecVersion('name: x\n  version: 9.9.9'), isNull);
      expect(parsePubspecVersion('name: x'), isNull);
    });

    test('fsp --version output', () {
      expect(parseFspVersion('fsp 0.1.1\n'), '0.1.1');
      expect(parseFspVersion('other 0.1.1'), isNull);
      expect(parseFspVersion(''), isNull);
    });

    test('checksum files', () {
      final hash = 'a' * 64;
      expect(parseChecksum('$hash  fsp-x.tar.gz\n'), hash);
      expect(parseChecksum('${hash.toUpperCase()} *fsp-x.zip'), hash);
      expect(parseChecksum('nothash  file'), isNull);
      expect(parseChecksum(''), isNull);
    });
  });

  group('cache directory', () {
    test('FSP_CACHE_DIR wins', () {
      expect(
        cacheRoot({'FSP_CACHE_DIR': '/c', 'HOME': '/h'}, os: 'linux'),
        '/c',
      );
    });

    test('per platform', () {
      expect(cacheRoot({'HOME': '/h'}, os: 'linux'), '/h/.cache/fespalier');
      expect(
        cacheRoot({'HOME': '/h', 'XDG_CACHE_HOME': '/x'}, os: 'linux'),
        '/x/fespalier',
      );
      expect(
        cacheRoot({'HOME': '/Users/me'}, os: 'macos'),
        '/Users/me/Library/Caches/fespalier',
      );
      expect(
        cacheRoot({'LOCALAPPDATA': r'C:\L'}, os: 'windows'),
        r'C:\L\fespalier',
      );
      expect(
        cacheRoot({'USERPROFILE': r'C:\U'}, os: 'windows'),
        r'C:\U\AppData\Local\fespalier',
      );
    });

    test('says what to do when there is no home', () {
      expect(
        () => cacheRoot({}, os: 'linux'),
        throwsA(isA<LauncherException>()),
      );
    });
  });

  group('sha256', () {
    test('standard vectors', () {
      expect(
        sha256Hex(const []),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        sha256Hex(utf8.encode('abc')),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(
        sha256Hex(
          utf8.encode(
            'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
          ),
        ),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
      expect(
        sha256Hex(List<int>.filled(1000000, 0x61)),
        'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
      );
    });

    test('matches sha256sum across padding boundaries', () async {
      final tool = await Process.run('sha256sum', [
        '--version',
      ]).then<bool>((r) => r.exitCode == 0, onError: (_) => false);
      if (!tool) {
        markTestSkipped('no sha256sum');
        return;
      }
      final dir = Directory.systemTemp.createTempSync('sha');
      addTearDown(() => dir.deleteSync(recursive: true));
      for (final n in [
        1,
        54,
        55,
        56,
        57,
        63,
        64,
        65,
        119,
        120,
        128,
        129,
        1000,
      ]) {
        final bytes = List<int>.generate(n, (i) => (i * 7 + 3) & 0xff);
        final f = File('${dir.path}/f')..writeAsBytesSync(bytes);
        final out = (await Process.run('sha256sum', [f.path])).stdout as String;
        expect(sha256Hex(bytes), out.split(' ').first, reason: 'length $n');
      }
    });
  });

  test('the pinned checksums are none, or belong to this package version', () {
    final version = parsePubspecVersion(
      File('pubspec.yaml').readAsStringSync(),
    );
    if (pinned.pinnedVersion.isEmpty) {
      expect(pinned.pinnedChecksums, isEmpty);
    } else {
      expect(pinned.pinnedVersion, version);
      for (final target in [
        'x86_64-unknown-linux-gnu',
        'aarch64-unknown-linux-gnu',
        'x86_64-apple-darwin',
        'aarch64-apple-darwin',
        'x86_64-pc-windows-msvc',
      ]) {
        expect(pinned.pinnedChecksums[target], matches(r'^[0-9a-f]{64}$'));
      }
    }
  });

  test('reads the version from the package pubspec', () async {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final lib = Directory.current.uri.resolve('lib/fespalier.dart');
    expect(await packageVersion(library: lib), parsePubspecVersion(pubspec));
  });

  group('Launcher', () {
    late Directory tmp;
    late Directory cache;
    late List<Uri> fetched;
    late List<String> probed;
    late List<String> logs;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('launcher');
      cache = Directory('${tmp.path}/cache')..createSync();
      fetched = [];
      probed = [];
      logs = [];
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Launcher launcher({
      Map<String, String> env = const {},
      Fetch? fetch,
      String? pathVersion,
      String target = 'x86_64-unknown-linux-gnu',
      String pinnedVersion = '',
      Map<String, String> pins = const {},
    }) => Launcher(
      version: '0.1.1',
      target: target,
      env: {'FSP_CACHE_DIR': cache.path, ...env},
      os: 'linux',
      fetch: (url) async {
        fetched.add(url);
        return fetch == null ? throw LauncherException('offline') : fetch(url);
      },
      log: logs.add,
      pinnedVersion: pinnedVersion,
      pins: pins,
      probe: (exe) async {
        probed.add(exe);
        return pathVersion == null ? null : 'fsp $pathVersion\n';
      },
    );

    /// A `.tar.gz` holding a shell script called `fsp`, and a fetch that serves it.
    Future<Fetch> release({String? sum, String file = 'fsp'}) async {
      final src = Directory('${tmp.path}/src')..createSync();
      File(
        '${src.path}/$file',
      ).writeAsStringSync('#!/bin/sh\necho "fsp 0.1.1"\n');
      await Process.run('chmod', ['+x', '${src.path}/$file']);
      final archive = File('${tmp.path}/fsp.tar.gz');
      final r = await Process.run('tar', [
        '-czf',
        archive.path,
        '-C',
        src.path,
        file,
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final bytes = archive.readAsBytesSync();
      return (Uri url) async {
        final name = url.pathSegments.last;
        if (name == 'fsp-x86_64-unknown-linux-gnu.tar.gz') return bytes;
        if (name == 'fsp-x86_64-unknown-linux-gnu.tar.gz.sha256') {
          return utf8.encode('${sum ?? sha256Hex(bytes)}  $name\n');
        }
        throw LauncherException('unexpected $url');
      };
    }

    final unix = !Platform.isWindows;

    test('FSP_BINARY is used as given, without any lookup', () async {
      final fake = File('${tmp.path}/my-fsp')..writeAsStringSync('');
      final l = launcher(env: {'FSP_BINARY': fake.path});
      expect(await l.locate(), fake.path);
      expect(fetched, isEmpty);
      expect(probed, isEmpty);
    });

    test('FSP_BINARY must exist', () {
      expect(
        () => launcher(env: {'FSP_BINARY': '${tmp.path}/nope'}).locate(),
        throwsA(isA<LauncherException>()),
      );
    });

    test('a cached binary needs no download and no probe', () async {
      final l = launcher();
      l.cachedBinary
        ..createSync(recursive: true)
        ..writeAsStringSync('');
      expect(await l.locate(), l.cachedBinary.path);
      expect(
        l.cachedBinary.path,
        '${cache.path}/0.1.1-x86_64-unknown-linux-gnu/fsp',
      );
      expect(fetched, isEmpty);
      expect(probed, isEmpty);
    });

    test('an fsp on PATH is used only when its version matches', () async {
      expect(await launcher(pathVersion: '0.1.1').locate(), 'fsp');
      expect(fetched, isEmpty);

      final l = launcher(
        pathVersion: '0.0.9',
        fetch: (_) async => throw LauncherException('no network'),
      );
      await expectLater(l.locate(), throwsA(isA<LauncherException>()));
      expect(
        fetched,
        hasLength(1),
        reason: 'a mismatched fsp on PATH falls through to the download',
      );
    });

    test('downloads once, verifies, caches and runs', () async {
      final l = launcher(fetch: await release());
      final path = await l.locate();
      expect(path, l.cachedBinary.path);
      expect(fetched.map((u) => u.toString()), [
        'https://github.com/vaam-apps/fespalier/releases/download/v0.1.1/fsp-x86_64-unknown-linux-gnu.tar.gz',
        'https://github.com/vaam-apps/fespalier/releases/download/v0.1.1/fsp-x86_64-unknown-linux-gnu.tar.gz.sha256',
      ]);
      final run = await Process.run(path, ['--version']);
      expect(run.stdout, 'fsp 0.1.1\n');
      expect(
        Directory(l.cachedBinary.parent.path).listSync().length,
        1,
        reason: 'no temp files left behind',
      );

      fetched.clear();
      expect(await launcher().locate(), path);
      expect(fetched, isEmpty, reason: 'second run reads the cache');
    }, skip: unix ? false : 'needs a unix shell');

    group('pinned checksums', () {
      const linux = 'x86_64-unknown-linux-gnu';

      test(
        'are the hard check; the release .sha256 is not even fetched',
        () async {
          final serve = await release();
          final bytes = await serve(Uri.parse('http://x/v/fsp-$linux.tar.gz'));
          final l = launcher(
            fetch: serve,
            pinnedVersion: '0.1.1',
            pins: {linux: sha256Hex(bytes)},
          );
          await l.locate();
          expect(fetched.map((u) => u.pathSegments.last), [
            'fsp-$linux.tar.gz',
          ]);
          expect(logs.where((m) => m.contains('warning')), isEmpty);
          expect(l.cachedBinary.existsSync(), isTrue);
        },
        skip: unix ? false : 'needs a unix shell',
      );

      test(
        'reject a release whose own .sha256 agrees with a tampered archive',
        () async {
          // The attacker replaces the archive and its .sha256; the pin in the package still wins.
          final l = launcher(
            fetch: await release(),
            pinnedVersion: '0.1.1',
            pins: {linux: 'b' * 64},
          );
          await expectLater(
            l.locate(),
            throwsA(
              isA<LauncherException>().having(
                (e) => e.message,
                'message',
                contains('checksum mismatch'),
              ),
            ),
          );
          expect(l.cachedBinary.parent.existsSync(), isFalse);
        },
        skip: unix ? false : 'needs a unix shell',
      );

      test(
        'of another version do not apply: falls back to .sha256 with a warning',
        () async {
          final l = launcher(
            fetch: await release(),
            pinnedVersion: '0.0.9',
            pins: {linux: 'b' * 64},
          );
          await l.locate();
          expect(fetched, hasLength(2));
          expect(logs.where((m) => m.contains('warning')), hasLength(1));
          expect(
            logs.singleWhere((m) => m.contains('warning')),
            allOf(contains('0.1.1'), contains('.sha256')),
          );
        },
        skip: unix ? false : 'needs a unix shell',
      );

      test(
        'without an entry for the target are an error, not a fallback',
        () async {
          final l = launcher(
            fetch: await release(),
            pinnedVersion: '0.1.1',
            pins: {'aarch64-apple-darwin': 'b' * 64},
          );
          await expectLater(
            l.locate(),
            throwsA(
              isA<LauncherException>().having(
                (e) => e.message,
                'message',
                allOf(contains('0.1.1'), contains(linux)),
              ),
            ),
          );
          expect(l.cachedBinary.existsSync(), isFalse);
        },
      );
    });

    group('offline', () {
      Fetch down() =>
          (url) async => throw const SocketException('Failed host lookup');

      test('with a cold cache is one line naming the version', () async {
        final l = launcher(fetch: down());
        await expectLater(
          l.locate(),
          throwsA(
            isA<LauncherException>().having(
              (e) => e.message,
              'message',
              "fsp 0.1.1 isn't cached and the download failed (offline?); "
                  'run once online or set FSP_BINARY',
            ),
          ),
        );
        expect(l.cachedBinary.parent.existsSync(), isFalse);
      });

      test('says the same when only the .sha256 is unreachable', () async {
        final serve = await release();
        final l = launcher(
          fetch: (url) => url.path.endsWith('.sha256')
              ? Future.error(const SocketException('gone'))
              : serve(url),
        );
        await expectLater(
          l.locate(),
          throwsA(
            isA<LauncherException>().having(
              (e) => e.message,
              'message',
              contains("fsp 0.1.1 isn't cached"),
            ),
          ),
        );
        expect(l.cachedBinary.existsSync(), isFalse);
      }, skip: unix ? false : 'needs a unix shell');

      test('with a warm cache never touches the network', () async {
        final l = launcher(fetch: down());
        l.cachedBinary
          ..createSync(recursive: true)
          ..writeAsStringSync('');
        expect(await l.locate(), l.cachedBinary.path);
        expect(fetched, isEmpty);
      });
    });

    test('FSP_BASE_URL redirects the download', () async {
      final l = launcher(
        env: {'FSP_BASE_URL': 'http://mirror.test/dl'},
        fetch: await release(),
      );
      await l.locate();
      expect(
        fetched.first.toString(),
        'http://mirror.test/dl/v0.1.1/fsp-x86_64-unknown-linux-gnu.tar.gz',
      );
    }, skip: unix ? false : 'needs a unix shell');

    test('a checksum mismatch aborts and caches nothing', () async {
      final l = launcher(fetch: await release(sum: '0' * 64));
      await expectLater(
        l.locate(),
        throwsA(
          isA<LauncherException>().having(
            (e) => e.message,
            'message',
            contains('checksum mismatch'),
          ),
        ),
      );
      expect(l.cachedBinary.existsSync(), isFalse);
      expect(l.cachedBinary.parent.existsSync(), isFalse);
    }, skip: unix ? false : 'needs a unix shell');

    test('an archive without the binary is an error', () async {
      final l = launcher(fetch: await release(file: 'other'));
      await expectLater(
        l.locate(),
        throwsA(
          isA<LauncherException>().having(
            (e) => e.message,
            'message',
            contains('did not contain fsp'),
          ),
        ),
      );
      expect(l.cachedBinary.existsSync(), isFalse);
      expect(
        l.cachedBinary.parent.listSync(),
        isEmpty,
        reason: 'temp files are cleaned up',
      );
    }, skip: unix ? false : 'needs a unix shell');

    test('run forwards the exit code', () async {
      final script = File('${tmp.path}/exit3')
        ..writeAsStringSync('#!/bin/sh\nexit 3\n');
      await Process.run('chmod', ['+x', script.path]);
      expect(await launcher(env: {'FSP_BINARY': script.path}).run(['x']), 3);
    }, skip: unix ? false : 'needs a unix shell');
  });
}
