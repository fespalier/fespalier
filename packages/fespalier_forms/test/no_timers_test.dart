// The rule, in code: the package starts no timer, schedules no work for later and never reads the
// wall clock. A form is built on a text controller and the hook that owns and disposes it, so
// listeners are allowed (the hook removes each one); a timer is not, because a test could not pump
// past it. This reads every file under lib/ and fails on the constructs that would break the rule,
// naming the file and the line.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Each construct, and why it is not allowed.
const forbidden = <String, String>{
  'Timer(':
      'a timer makes a test flaky: a form changes on an event, never on a schedule',
  'Timer.periodic': 'a periodic timer is work on a schedule',
  'Timer.run': 'scheduled work',
  'Future.delayed': 'a delay is a timer',
  'Stream.periodic': 'a periodic stream is a timer',
  '.timeout(': 'Future.timeout starts a timer',
  'scheduleMicrotask': 'work nobody asked for: a sync submit stays sync',
  'Future.microtask': 'work nobody asked for: a sync submit stays sync',
  'DateTime.now()': 'the form reads no clock',
};

/// The problems in [lines], one per forbidden construct on a line of code (comments are not code).
List<String> violations(String path, List<String> lines) {
  final problems = <String>[];
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trimLeft().startsWith('//')) continue;
    final code = lines[i].split(' // ').first;
    for (final entry in forbidden.entries) {
      if (code.contains(entry.key)) {
        problems.add('$path:${i + 1}: ${entry.key} (${entry.value})');
      }
    }
  }
  return problems;
}

/// An async provider is where a plugin's or a store's `Exception` ends up, and Riverpod 3 retries a
/// provider that fails with one: a `Timer` after 200 ms, doubling, up to ten times. So the
/// declaration of every future, stream and async notifier provider says `retry:` (`retry: (_, _) =>
/// null` to opt out). A sync provider fails only for a programming error, an `Error`, which is
/// never retried. (A record in the type arguments hides a declaration from this pattern.)
final asyncProvider = RegExp(
  r'\b(?:Future|Stream|AsyncNotifier|StreamNotifier)Provider'
  r'(?:\s*\.\s*(?:autoDispose|family))*\s*(?:<[\w\s,<>?.]*>)?\s*\(',
);

/// [source] with every comment and every string blanked (newlines stay), so what is left is code
/// and its brackets balance.
String blanked(String source) {
  final out = StringBuffer();
  var i = 0;
  void blank(int to) {
    final end = to > source.length ? source.length : to;
    for (; i < end; i++) {
      out.write(source[i] == '\n' ? '\n' : ' ');
    }
  }

  while (i < source.length) {
    final c = source[i];
    if (source.startsWith('//', i)) {
      final end = source.indexOf('\n', i);
      blank(end < 0 ? source.length : end);
    } else if (source.startsWith('/*', i)) {
      final end = source.indexOf('*/', i + 2);
      blank(end < 0 ? source.length : end + 2);
    } else if (c == "'" || c == '"') {
      final triple = source.startsWith(c * 3, i);
      final raw = i > 0 && source[i - 1] == 'r';
      var j = i + (triple ? 3 : 1);
      while (j < source.length &&
          !(triple ? source.startsWith(c * 3, j) : source[j] == c)) {
        j += source[j] == r'\' && !raw ? 2 : 1;
      }
      blank(j + (triple ? 3 : 1));
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}

/// The async providers declared in [source] that do not pass `retry:` as one of their own
/// arguments (one in a nested call is not theirs), as `path:line`.
List<String> unretried(String path, String source) {
  final code = blanked(source);
  final problems = <String>[];
  for (final m in asyncProvider.allMatches(code)) {
    var depth = 0;
    final own = StringBuffer();
    for (var i = m.end - 1; i < code.length; i++) {
      final c = code[i];
      if ('([{'.contains(c)) {
        depth++;
      } else if (')]}'.contains(c)) {
        if (--depth == 0) break;
      } else if (depth == 1) {
        own.write(c);
      }
    }
    if (!RegExp(r'\bretry\s*:').hasMatch(own.toString())) {
      final line = '\n'.allMatches(code.substring(0, m.start)).length + 1;
      final shown = m.group(0)!.replaceAll(RegExp(r'\s+'), ' ');
      problems.add(
        '$path:$line: $shown has no retry: (Riverpod 3 retries an Exception '
        'with a Timer; pass `retry: (_, _) => null`)',
      );
    }
  }
  return problems;
}

void main() {
  test('no file under lib/ starts a timer, a delay or a microtask', () {
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
  });

  test('the check catches each construct, and ignores comments', () {
    for (final line in [
      'final t = Timer(d, f);',
      'Timer.periodic(d, f);',
      'Timer.run(f);',
      'await Future.delayed(d);',
      'Stream.periodic(d);',
      'x.timeout(d);',
      'scheduleMicrotask(f);',
      'Future.microtask(f);',
      'final now = DateTime.now();',
    ]) {
      expect(violations('f.dart', [line]), hasLength(1), reason: line);
    }
    expect(
      violations('f.dart', [
        '/// Timer(d, f) is not used.',
        '// DateTime.now()',
      ]),
      isEmpty,
    );
    expect(violations('f.dart', ['final x = 1; // not a Timer(']), isEmpty);
    expect(violations('f.dart', ['controller.addListener(f);']), isEmpty);
  });

  test('every future, stream and async notifier provider says `retry:`', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
    expect(files, isNotEmpty);
    final problems = [
      for (final file in files)
        ...unretried(file.path, file.readAsStringSync()),
    ];
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('the retry check sees each declaration, and only those', () {
    for (final source in [
      'final a = FutureProvider<int>((ref) async => 1);',
      'final a = FutureProvider.autoDispose<int>((ref) async => 1);',
      'final a = FutureProvider.autoDispose.family<int, String?>((ref, k) async => 1);',
      'final a = StreamProvider<List<int>>((ref) => s);',
      'final a = AsyncNotifierProvider<N, int>(N.new);',
      'final a = StreamNotifierProvider.autoDispose<N, int>(N.new);',
      'final a = FutureProvider<int>(\n  (ref) async {\n    return 1;\n  },\n);',
      // A retry that is another call's is not the provider's.
      'final a = FutureProvider<int>((ref) => ref.read(x).load(retry: 3));',
      "final a = FutureProvider<int>((ref) => 1, name: 'retry: no');",
    ]) {
      expect(unretried('f.dart', source), hasLength(1), reason: source);
    }
    for (final source in [
      'final a = FutureProvider<int>((ref) async => 1, retry: (_, _) => null);',
      'final a = FutureProvider.autoDispose<int>((ref) async => 1, retry : r);',
      'final a = StreamProvider<int>(\n  (ref) => s,\n  name: "x",\n  retry: (count, error) => null,\n);',
      'final a = AsyncNotifierProvider.autoDispose.family<N, int, S>(N.new, retry: r);',
      // Not declarations: a type, a comment, a string, a sync provider.
      'final StreamProvider<int> a;',
      'StreamProvider<Change<E>> latest;\nvoid topic<K>() {}',
      '// final a = FutureProvider<int>((ref) async => 1);',
      '/// FutureProvider<int>(f)\nfinal a = 1;',
      "final a = 'FutureProvider<int>(f)';",
      'final a = Provider<int>((ref) => 1);',
      'final a = NotifierProvider<N, int>(N.new);',
    ]) {
      expect(unretried('f.dart', source), isEmpty, reason: source);
    }
    expect(
      unretried('f.dart', 'x\ny\nfinal a = FutureProvider<int>(f);').single,
      startsWith('f.dart:3:'),
    );
  });
}
