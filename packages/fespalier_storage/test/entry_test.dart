import 'package:fespalier_storage/src/entry.dart';
import 'package:flutter_test/flutter_test.dart';

const s2 =
    'FormatException: fespalier_storage: a saved entry is not one this storage wrote (format fsc1)';

/// What decoding [stored] throws, as the text a log prints.
String unreadable(String stored) {
  try {
    decodeEntry(stored);
  } on FormatException catch (error) {
    return error.toString();
  }
  fail('decoded ${stored.replaceAll('\n', r'\n')}');
}

void main() {
  final written = DateTime.utc(2026, 10, 3, 12, 30, 15, 250);

  group('round trip', () {
    test('with an expiry', () {
      final expire = written.add(const Duration(days: 2));
      final entry = decodeEntry(
        encodeEntry(
          Entry(data: '{"name":"ACME"}', writtenAt: written, expireAt: expire),
        ),
      );
      expect(entry.data, '{"name":"ACME"}');
      expect(entry.writtenAt, written);
      expect(entry.writtenAt.isUtc, isTrue);
      expect(entry.expireAt, expire);
      expect(entry.destroyKey, isNull);
      expect(entry.key, isNull);
    });

    test('without one', () {
      final entry = decodeEntry(
        encodeEntry(Entry(data: 'x', writtenAt: written)),
      );
      expect(entry.expireAt, isNull);
      expect(entry.data, 'x');
    });

    test('is the five header lines and the data, as documented', () {
      final text = encodeEntry(
        Entry(
          data: 'the data',
          writtenAt: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
          expireAt: DateTime.fromMillisecondsSinceEpoch(2000, isUtc: true),
          destroyKey: '2',
        ),
      );
      expect(text, 'fsc1\n2000\n1000\n"2"\n\nthe data');
      expect(
        encodeEntry(
          Entry(
            data: '',
            writtenAt: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
          ),
        ),
        'fsc1\n\n1000\nnull\n\n',
      );
    });

    test('a destroyKey that is null, plain, or has quotes and a newline', () {
      for (final destroyKey in <String?>[
        null,
        'v2',
        'say "hi"',
        'two\nlines',
        r'back\slash',
        '',
      ]) {
        final text = encodeEntry(
          Entry(data: 'd', writtenAt: written, destroyKey: destroyKey),
        );
        expect(
          text.split('\n'),
          hasLength(6),
          reason: 'a newline in a destroyKey is escaped: one header line',
        );
        expect(decodeEntry(text).destroyKey, destroyKey);
      }
    });

    test(
      'data with newlines, and one that starts with fsc1, is the data whole',
      () {
        for (final data in [
          'a\nb\n',
          '\n\n\n',
          'fsc1\n1\n2\nnull\n\nfsc1',
          '',
          '"quoted"\n',
        ]) {
          final entry = decodeEntry(
            encodeEntry(Entry(data: data, writtenAt: written, destroyKey: 'k')),
          );
          expect(entry.data, data);
        }
      },
    );

    test('the key line of a hashed key', () {
      const key = 'fespalier:products/\$id[42]\nwith "odd" characters é';
      final text = encodeEntry(Entry(data: 'd', writtenAt: written, key: key));
      expect(
        text.split('\n').length,
        6,
        reason: 'one line, whatever the key holds',
      );
      expect(decodeEntry(text).key, key);
    });
  });

  group('an entry it did not write is the S2 error', () {
    test('fewer than five newlines', () {
      expect(unreadable(''), s2);
      expect(unreadable('fsc1'), s2);
      expect(
        unreadable('fsc1\n\n1\nnull\n'),
        s2,
      ); // the key line has no newline: four newlines
      expect(unreadable('fsc1\n\n1\nnull'), s2);
    });

    test('another first line', () {
      expect(unreadable('fsc2\n\n1\nnull\n\ndata'), s2);
      expect(unreadable('FSC1\n\n1\nnull\n\ndata'), s2);
      expect(unreadable('\n\n1\nnull\n\ndata'), s2);
      expect(unreadable('{"json": true}\n\n1\nnull\n\nx'), s2);
    });

    test('a time that is not an integer', () {
      expect(unreadable('fsc1\nsoon\n1\nnull\n\nd'), s2);
      expect(unreadable('fsc1\n\nyesterday\nnull\n\nd'), s2);
      expect(
        unreadable('fsc1\n\n\nnull\n\nd'),
        s2,
        reason: 'writtenAt is not optional',
      );
      expect(unreadable('fsc1\n\n1.5\nnull\n\nd'), s2);
      expect(unreadable('fsc1\n\n-5\nnull\n\nd'), s2);
      expect(unreadable('fsc1\n\n0x10\nnull\n\nd'), s2);
      expect(
        unreadable('fsc1\n\n99999999999999999\nnull\n\nd'),
        s2,
        reason: 'out of the range of a DateTime',
      );
    });

    test('a destroyKey that is not null or a JSON string', () {
      expect(unreadable('fsc1\n\n1\n\n\nd'), s2, reason: 'empty is not null');
      expect(unreadable('fsc1\n\n1\nv2\n\nd'), s2);
      expect(unreadable('fsc1\n\n1\n2\n\nd'), s2);
      expect(unreadable('fsc1\n\n1\n["v2"]\n\nd'), s2);
      expect(unreadable('fsc1\n\n1\n"unterminated\n\nd'), s2);
    });

    test('a key line that is neither empty nor a JSON string', () {
      expect(unreadable('fsc1\n\n1\nnull\nplain\nd'), s2);
      expect(unreadable('fsc1\n\n1\nnull\n7\nd'), s2);
    });

    test('the message is the documented one', () {
      expect(
        unreadableEntryMessage,
        'fespalier_storage: a saved entry is not one this storage wrote (format fsc1)',
      );
    });
  });
}
