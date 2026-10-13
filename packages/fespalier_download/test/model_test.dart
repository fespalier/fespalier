import 'package:fespalier_download/fespalier_download.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadRequest request({
  String id = 'a',
  String url = 'https://example.com/file.bin',
  DownloadLocation file = const DownloadLocation(
    DownloadBase.support,
    'packs/file.bin',
  ),
  Map<String, String> headers = const {},
  int? bytes,
  String? sha256,
}) => DownloadRequest(
  id: id,
  url: Uri.parse(url),
  file: file,
  headers: headers,
  bytes: bytes,
  sha256: sha256,
);

void main() {
  group('DownloadLocation.isValid', () {
    test('accepts relative paths', () {
      for (final path in ['a', 'a/b', 'a/b.c', 'a b/c', '.hidden', 'a/.b']) {
        expect(
          DownloadLocation(DownloadBase.support, path).isValid,
          isTrue,
          reason: path,
        );
      }
    });

    test('refuses everything that could leave the base folder', () {
      for (final path in [
        '',
        '..',
        '../x',
        'a/../x',
        'a/..',
        '/x',
        '/',
        'a//b',
        'a/',
        r'a\b',
        r'..\x',
        'a\u0000b',
        '\u0000',
      ]) {
        expect(
          DownloadLocation(DownloadBase.cache, path).isValid,
          isFalse,
          reason: path,
        );
      }
    });

    test('is equal by base and path, and prints the base only', () {
      const a = DownloadLocation(DownloadBase.support, 'secret/name.pdf');
      const b = DownloadLocation(DownloadBase.support, 'secret/name.pdf');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        a,
        isNot(const DownloadLocation(DownloadBase.cache, 'secret/name.pdf')),
      );
      expect(a.toString(), isNot(contains('secret')));
      expect(a.toString(), isNot(contains('name.pdf')));
    });
  });

  group('DownloadRequest.isValid', () {
    test('accepts a complete request', () {
      expect(request().isValid, isTrue);
      expect(request(url: 'http://example.com/x').isValid, isTrue);
      expect(request(bytes: 0).isValid, isTrue);
      expect(request(sha256: 'A' * 64).isValid, isTrue);
      expect(request(sha256: 'a1' * 32).isValid, isTrue);
      expect(request(headers: {'Range': 'x'}).isValid, isTrue);
    });

    test('refuses an empty id', () {
      expect(request(id: '').isValid, isFalse);
    });

    test(
      'refuses a URL that is not an absolute http or https URL with a host',
      () {
        for (final url in [
          'file:///etc/passwd',
          'ftp://example.com/x',
          'content://x/y',
          '/relative/path',
          'example.com/x',
          'https:///nohost',
          'https://user:pass@example.com/x',
          'https://user@example.com/x',
        ]) {
          expect(request(url: url).isValid, isFalse, reason: url);
        }
      },
    );

    test('refuses an invalid file', () {
      expect(
        request(
          file: const DownloadLocation(DownloadBase.support, '../x'),
        ).isValid,
        isFalse,
      );
      expect(
        request(
          file: const DownloadLocation(DownloadBase.support, '/abs'),
        ).isValid,
        isFalse,
      );
    });

    test('refuses a negative size', () {
      expect(request(bytes: -1).isValid, isFalse);
    });

    test('refuses a digest that is not 64 hex digits', () {
      for (final digest in [
        '',
        'abc',
        'g' * 64,
        'a' * 63,
        'a' * 65,
        ' ${'a' * 63}',
      ]) {
        expect(request(sha256: digest).isValid, isFalse, reason: digest);
      }
    });

    test('refuses an empty header name', () {
      expect(request(headers: {'': 'x'}).isValid, isFalse);
      expect(request(headers: {'  ': 'x'}).isValid, isFalse);
    });

    test('has the documented defaults', () {
      final r = request();
      expect(r.network, DownloadNetwork.any);
      expect(r.priority, DownloadPriority.background);
      expect(r.headers, isEmpty);
      expect(r.bytes, isNull);
      expect(r.sha256, isNull);
      expect(r.displayName, isNull);
    });

    test('toString prints no field', () {
      final r = DownloadRequest(
        id: 'order-4711',
        url: Uri.parse('https://cdn.example.com/signed?token=SECRETTOKEN'),
        file: const DownloadLocation(
          DownloadBase.documents,
          'invoices/jane.pdf',
        ),
        headers: const {'Authorization': 'Bearer SECRETBEARER'},
        sha256: 'a' * 64,
        displayName: 'Jane Doe invoice',
      );
      expect(r.toString(), 'DownloadRequest');
      expect('$r', isNot(contains('SECRET')));
      expect('$r', isNot(contains('4711')));
      expect('$r', isNot(contains('jane')));
      expect('$r', isNot(contains('Jane')));
      expect('$r', isNot(contains('cdn.example.com')));
      expect('$r', isNot(contains('Bearer')));
    });

    test('a stored download prints no field either', () {
      final stored = StoredDownload(
        DownloadRequest(
          id: 'order-4711',
          url: Uri.parse('https://cdn.example.com/x?token=SECRET'),
          file: const DownloadLocation(DownloadBase.support, 'x'),
        ),
      );
      expect(stored.toString(), 'StoredDownload');
      expect(stored.next().generation, 1);
      expect(stored.next().request, same(stored.request));
    });
  });

  group('DownloadStatus', () {
    test('values are equal by content', () {
      const file = DownloadLocation(DownloadBase.support, 'f');
      expect(const Running(1, 2), const Running(1, 2));
      expect(const Running(1, 2), isNot(const Running(1)));
      expect(const Paused(1), const Paused(1));
      expect(const Paused(1), isNot(const Running(1)));
      expect(const Waiting(WaitReason.retry), const Waiting(WaitReason.retry));
      expect(
        const Waiting(WaitReason.retry),
        isNot(const Waiting(WaitReason.slot)),
      );
      expect(const Complete(file, 3), const Complete(file, 3));
      expect(const Complete(file, 3), isNot(const Complete(file, 4)));
      expect(
        const Failed(DownloadFailure.network),
        const Failed(DownloadFailure.network),
      );
      expect(
        const Failed(DownloadFailure.network),
        isNot(const Failed(DownloadFailure.other)),
      );
      expect(const Absent(), const Absent());
      expect(const Queued(), const Queued());
      expect(const Verifying(), const Verifying());
      expect(const Cancelled(), const Cancelled());
      expect(const Queued(), isNot(const Absent()));
      expect(const Running(1, 2).hashCode, const Running(1, 2).hashCode);
    });

    test('a switch over the sealed family is exhaustive', () {
      String name(DownloadStatus s) => switch (s) {
        Absent() => 'absent',
        Queued() => 'queued',
        Waiting() => 'waiting',
        Running() => 'running',
        Paused() => 'paused',
        Verifying() => 'verifying',
        Complete() => 'complete',
        Failed() => 'failed',
        Cancelled() => 'cancelled',
      };
      expect(name(const Running(0)), 'running');
    });

    test('toString prints the state and numbers, never the path', () {
      const done = Complete(
        DownloadLocation(DownloadBase.support, 'secret/a.pdf'),
        10,
      );
      expect(done.toString(), isNot(contains('secret')));
      expect(done.toString(), isNot(contains('a.pdf')));
      expect(const Running(5, 10).toString(), 'Running(5/10)');
      expect(const Running(5).toString(), 'Running(5/?)');
      expect(
        const Failed(DownloadFailure.hashMismatch).toString(),
        'Failed(hashMismatch)',
      );
    });
  });

  test('DownloadCapabilities claims nothing by default', () {
    const c = DownloadCapabilities();
    expect(c.pause, isFalse);
    expect(c.resumeAcrossRestart, isFalse);
    expect(c.background, isFalse);
    expect(c.userInitiated, isFalse);
    expect(c.unmetered, isFalse);
    expect(c.notifications, isFalse);
  });
}
