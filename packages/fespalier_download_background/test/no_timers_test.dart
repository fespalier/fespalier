// The rules, in code. The package starts no timer, schedules nothing for later and listens to
// nothing of its own (the operating system reports through the callbacks it registers for its
// own group), and it opens nothing: no dialog, no menu, no picker dialog, and it never asks for
// the notification permission (that is the app's). It touches the plugin only for its own group:
// it never listens to the app's `FileDownloader().updates` stream and never calls a global of the
// plugin. This reads every file under lib/ and fails on the constructs that would break a rule,
// naming the file and the line.
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
  RegExp(r'\.listen(Manual)?\s*\('):
      'a listener outlives the call that made it: watch, so Riverpod rebuilds',
  RegExp(r'\baddListener\s*\('): 'a listener outlives the call that made it',
  RegExp(r'\baddPostFrameCallback\b'): 'a frame nobody asked for',
  RegExp(r'\bRandom\s*\(\s*\)'):
      'ids come from Random.secure(): a seeded generator makes an id guessable',
};

/// The plugin's globals and the app's own stream: nothing in this package touches them, because
/// the plugin is one per app and these belong to the app.
final plugin = <RegExp, String>{
  RegExp(r'\.\s*updates\b'): "FileDownloader().updates is a single-subscription stream and the app's own",
  RegExp(
    r'\.\s*(start|reset|resetUpdates|destroy|configure|configureNotification|trackTasks|rescheduleKilledTasks|requireWiFi|addTaskQueue)\s*\(',
  ): "a global of the plugin: this package uses its own group's calls only",
  RegExp(r'\.\s*transfers\b'): "the plugin's Transfer API is not used",
  RegExp(r'\bConfig\s*\.'): "the plugin's global configuration is the app's",
  RegExp(r'\bPermissions\b|\.\s*permissions\b'):
      "the notification permission is the app's: this package never asks",
};

/// The calls that register or remove callbacks, and the construction of the plugin itself. They
/// are allowed in the one file that calls the plugin, and nowhere else.
final pluginEntry = <RegExp, String>{
  RegExp(r'\bregisterCallbacks\s*\('): 'registering callbacks',
  RegExp(r'\bunregisterCallbacks\s*\('): 'removing callbacks',
  RegExp(r'\bFileDownloader\s*\('): 'constructing the plugin',
};

/// The only file that may call [pluginEntry]'s constructs.
const pluginFile = 'plugin_transport.dart';

/// What would open something over the page: this package is a body, and the app decides what
/// else is on screen (the project's rules are bottom sheets for questions, no dialogs, no menus).
final dialogs = <RegExp, String>{
  RegExp(r'\bshow(General|Cupertino|Adaptive)?Dialog\b'): 'a dialog',
  RegExp(r'\b(Alert|Simple|Cupertino[A-Za-z]*)Dialog\b'): 'a dialog',
  RegExp(r'\bDialog\s*\('): 'a dialog',
  RegExp(r'\bshow(Date|Time|DateRange)Picker\b'): 'a picker dialog',
  RegExp(r'\bshow(Modal)?BottomSheet\b'): 'a sheet nobody asked for',
  RegExp(r'\bshowMenu\b|\bPopupMenuButton\b|\bMenuAnchor\b|\bDropdown\w*\b'):
      'a menu',
  RegExp(r'\bshowSearch\b|\bSnackBar\b|\bshowSnackBar\b'):
      'a message over the page',
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

/// The problems in [lines], one per construct of [table] on a line of code (comments are not
/// code).
List<String> violations(
  String path,
  List<String> lines, [
  Map<RegExp, String>? table,
]) {
  final problems = <String>[];
  final code = codeOf(lines);
  for (var i = 0; i < code.length; i++) {
    for (final entry in (table ?? forbidden).entries) {
      if (entry.key.hasMatch(code[i])) {
        problems.add('$path:${i + 1}: ${entry.key.pattern} (${entry.value})');
      }
    }
  }
  return problems;
}

List<File> libFiles() {
  final files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
  expect(files, isNotEmpty);
  return files;
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
  test('no file under lib/ starts a timer, a delay, a listener or reads the wall clock', () {
    final problems = [
      for (final file in libFiles())
        ...violations(file.path, file.readAsLinesSync()),
    ];
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test(
    "no file under lib/ touches the plugin's globals or the app's stream",
    () {
      final problems = [
        for (final file in libFiles())
          ...violations(file.path, file.readAsLinesSync(), plugin),
      ];
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  test('only the plugin transport registers callbacks, and it does', () {
    final problems = <String>[];
    var entry = 0;
    for (final file in libFiles()) {
      final found = violations(file.path, file.readAsLinesSync(), pluginEntry);
      if (file.path.endsWith(pluginFile)) {
        entry += found.length;
      } else {
        problems.addAll(found);
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
    // The exception is not stale: the file really registers, unregisters and constructs.
    expect(entry, greaterThanOrEqualTo(3));
  });

  test('no file under lib/ opens a dialog, a menu, a sheet or a message', () {
    final problems = [
      for (final file in libFiles())
        ...violations(file.path, file.readAsLinesSync(), dialogs),
    ];
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test(
    'the timer check catches each construct, spelled the ways Dart allows',
    () {
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
    },
  );

  test('the plugin checks catch each construct', () {
    for (final line in [
      'FileDownloader().updates.listen(print);',
      'final s = downloader.updates;',
      'FileDownloader().start();',
      'downloader.reset();',
      'await FileDownloader().rescheduleKilledTasks();',
      'downloader.configure(globalConfig: x);',
      'downloader.transfers.start(t);',
      'Config.runInForeground',
      'await FileDownloader().permissions.request(t);',
    ]) {
      expect(violations('f.dart', [line], plugin), isNotEmpty, reason: line);
    }
    for (final line in [
      'registerCallbacks(group: g);',
      'unregisterCallbacks(group: g);',
      'FileDownloader();',
    ]) {
      expect(violations('f.dart', [line], pluginEntry), isNotEmpty);
    }
    for (final line in [
      'updates: bd.Updates.statusAndProgress,',
      'await _transport.track(group);',
      'final x = restart();',
    ]) {
      expect(violations('f.dart', [line], plugin), isEmpty, reason: line);
    }
  });

  test('the dialog check catches each construct', () {
    for (final line in [
      'showDialog(context: c, builder: b);',
      'showAdaptiveDialog(context: c);',
      'showGeneralDialog(context: c);',
      'return AlertDialog(title: t);',
      'const SimpleDialog();',
      'CupertinoAlertDialog(',
      'Dialog(child: c);',
      'showDatePicker(context: c);',
      'showTimePicker(context: c);',
      'showModalBottomSheet(context: c);',
      'showBottomSheet(context: c);',
      'showMenu(context: c);',
      'PopupMenuButton<int>(',
      'MenuAnchor(',
      'DropdownButton<int>(',
      'DropdownMenu<int>(',
      'showSearch(context: c);',
      'ScaffoldMessenger.of(c).showSnackBar(s);',
    ]) {
      expect(violations('f.dart', [line], dialogs), isNotEmpty, reason: line);
    }
  });

  test('the checks ignore comments, and what is not a construct', () {
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
    expect(
      violations('f.dart', [
        '/// Nothing here calls showDialog or builds an AlertDialog.',
        '// showModalBottomSheet',
        'final dialogs = 1;',
        'const GeoPoint(1, 2);',
      ], dialogs),
      isEmpty,
    );
  });

  test('a block comment that spans lines hides its lines and no more', () {
    final lines = ['/*', 'Timer(d, f);', '*/ Timer(d, f);', 'Timer(d, f);'];
    expect(violations('f.dart', lines), hasLength(2));
    expect(violations('f.dart', lines).first, startsWith('f.dart:3:'));
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
