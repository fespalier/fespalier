// The rule, in code: the package starts no timer, schedules nothing for later and listens to
// nothing, with one documented exception: `container.listen(` in lib/fespalier_adapter.dart, the
// adapter seam ("Hold what you subscribe in a provider of [container]"), so the subscription goes
// with the ProviderScope. A source's streams reach the app through Riverpod, never a raw
// `.listen`. This reads every file under lib/ and fails on the constructs that
// would break the rule, naming the file and the line.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Each construct as a pattern (so `Future<void>.delayed(` and `Timer (` do not slip through), and
/// why it is not allowed.
final forbidden = <RegExp, String>{
  RegExp(r'\bTimer\s*\('):
      'a timer keeps the radio busy and makes a test flaky',
  RegExp(r'\bTimer\s*\.\s*(periodic|run)\b'):
      'a periodic timer is work nobody asked for: the app owns the ticker',
  RegExp(r'\bFuture\s*(<[^>]*>)?\s*\.\s*(delayed|microtask)\s*\('):
      'a delay is a timer, and a microtask is work nobody asked for',
  RegExp(r'\bFuture\s*(<[^>]*>)?\s*\('):
      'Future(() ...) is Timer.run in disguise',
  RegExp(r'\bStream\s*(<[^>]*>)?\s*\.\s*periodic\b'):
      'a periodic stream is a timer',
  RegExp(r'\.timeout\s*\('):
      "Future.timeout starts a timer: let the caller's client time out",
  RegExp(r'\bscheduleMicrotask\b'): 'work nobody asked for',
  RegExp(r'\bDateTime\s*\.\s*(now|timestamp)\s*\('):
      'read the clock through package:clock, so a test can move time',
  RegExp(r'\.listen(Manual)?\s*(<[^(]*>)?\s*\('):
      'a listener outlives the call that made it: watch, so Riverpod rebuilds',
  RegExp(r'\baddListener\s*\('): 'a listener outlives the call that made it',
  RegExp(r'\baddPostFrameCallback\b'): 'a frame nobody asked for',
  RegExp(
    r'\bRandom\s*\(\s*\)',
  ): 'ids come from Random.secure(): a seeded generator makes an idempotency key guessable',
};

/// [lines] as code: block comments and line comments removed (a `//` that is part of a URL in a
/// string, preceded by a colon, stays), keeping the line numbers.
List<String> codeOf(List<String> lines) {
  var inBlock = false;
  final out = <String>[];
  for (final line in lines) {
    var rest = line;
    final code = StringBuffer();
    while (rest.isNotEmpty) {
      if (inBlock) {
        final end = rest.indexOf('*/');
        if (end < 0) {
          rest = '';
        } else {
          inBlock = false;
          rest = rest.substring(end + 2);
        }
        continue;
      }
      final block = rest.indexOf('/*');
      final lineComment = RegExp(r'(?<!:)//').firstMatch(rest)?.start ?? -1;
      if (lineComment >= 0 && (block < 0 || lineComment < block)) {
        code.write(rest.substring(0, lineComment));
        rest = '';
      } else if (block >= 0) {
        code.write(rest.substring(0, block));
        inBlock = true;
        rest = rest.substring(block + 2);
      } else {
        code.write(rest);
        rest = '';
      }
    }
    out.add(code.toString());
  }
  return out;
}

/// The one allowed construct: a `container.listen` in the adapter file, by file and pattern.
final allowedListen = RegExp(r'\bcontainer\s*\.\s*listen\s*(<[^(]*>)?\s*\(');

/// Whether [path] is the adapter file, where [allowedListen] is permitted.
bool isAdapterFile(String path) =>
    path.replaceAll(r'\', '/').endsWith('lib/fespalier_adapter.dart');

/// The problems in [lines], one per forbidden construct on a line of code (comments are not code).
List<String> violations(String path, List<String> lines) {
  final problems = <String>[];
  final code = codeOf(lines);
  for (var i = 0; i < code.length; i++) {
    for (final entry in forbidden.entries) {
      if (entry.key.hasMatch(code[i])) {
        if (isAdapterFile(path) &&
            entry.key.pattern.contains('listen') &&
            allowedListen.hasMatch(code[i]) &&
            !RegExp(
              r'(?<!container)\s*\.listen',
            ).hasMatch(code[i].replaceAll(allowedListen, ''))) {
          continue;
        }
        problems.add('$path:${i + 1}: ${entry.key.pattern} (${entry.value})');
      }
    }
  }
  return problems;
}

void main() {
  test(
    'no file under lib/ starts a timer, a delay, a listener or reads the wall clock',
    () {
      final files = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();
      expect(files, isNotEmpty);
      final problems = [
        for (final file in files)
          ...violations(file.path, file.readAsLinesSync()),
      ];
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  test('the check catches each construct, spelled the ways Dart allows', () {
    for (final line in [
      'final t = Timer(d, f);',
      'final t = Timer (d, f);',
      'Timer.periodic(d, f);',
      'Timer .periodic(d, f);',
      'Timer.run(f);',
      'await Future.delayed(d);',
      'await Future<void>.delayed(d);',
      'await Future <void> .delayed(d);',
      'Future.microtask(f);',
      'Future<int>.microtask(f);',
      'Future(() => 1);',
      'Future<int>(() => 1);',
      'Stream.periodic(d);',
      'Stream<int>.periodic(d);',
      'x.timeout(d);',
      'scheduleMicrotask(f);',
      'final now = DateTime.now();',
      'final now = DateTime.timestamp();',
      'stream.listen(print);',
      'stream.listen<int>(print);',
      'ref.listen<int>(p, f);',
      'ref.listenManual(p, f);',
      'notifier.addListener(f);',
      'binding.addPostFrameCallback(f);',
      'final r = Random();',
      'final r = Random( );',
      'final t = 1;/* hidden */ Timer(d, f);',
      'foo(); //no space\nTimer(d, f);'.split('\n').last,
    ]) {
      expect(violations('f.dart', [line]), isNotEmpty, reason: line);
    }
  });

  test('the check ignores comments, and what is not a construct', () {
    expect(
      violations('f.dart', [
        '/// Timer(d, f) is not used.',
        '// DateTime.now()',
        'final x = 1; // not a Timer(',
        'final x = 1; //Timer(',
        '/* Timer(d, f);',
        '   Future.delayed(d); */ final ok = 1;',
        '/* Timer( */ final y = 2;',
      ]),
      isEmpty,
    );
    for (final line in [
      'final now = clock.now();',
      'final r = Random.secure();',
      'return Future<void>.value();',
      'Future.value().then((_) => 1);',
      'await Future.wait<int>([a, b]);',
      'final f = Future.sync(() => 1);',
      'final url = "https://example.com";',
    ]) {
      expect(violations('f.dart', [line]), isEmpty, reason: line);
    }
  });

  test('container.listen is allowed in the adapter file and nowhere else', () {
    const line = '    container.listen<AsyncValue<int>>(p, (a, b) {});';
    expect(violations('lib/fespalier_adapter.dart', [line]), isEmpty);
    expect(violations(r'lib\fespalier_adapter.dart', [line]), isEmpty);
    expect(violations('lib/src/other.dart', [line]), isNotEmpty);
    expect(violations('lib/testing.dart', [line]), isNotEmpty);
    expect(
      violations('lib/fespalier_adapter.dart', [
        'container.listen(p, f); stream.listen(f);',
        'ref.listen(p, f);',
        'source.taps.listen(f);',
      ]),
      hasLength(3),
    );
  });

  test('a block comment that spans lines hides its lines and no more', () {
    final lines = ['/*', 'Timer(d, f);', '*/ Timer(d, f);', 'Timer(d, f);'];
    expect(violations('f.dart', lines), hasLength(2));
    expect(violations('f.dart', lines).first, startsWith('f.dart:3:'));
  });
}
