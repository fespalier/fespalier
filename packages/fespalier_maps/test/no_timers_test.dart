// The rules, in code. The package starts no timer, schedules nothing for later and listens to
// nothing (a map reports through callbacks the widget hands it, a geocoder answers a Future), and
// it opens nothing: no dialog, no menu, no picker dialog (the OS permission prompt is the
// platform's own). This reads every file under lib/ and fails on the constructs that would break
// a rule, naming the file and the line.
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

void main() {
  test(
    'no file under lib/ starts a timer, a delay, a listener or reads the wall clock',
    () {
      final problems = [
        for (final file in libFiles())
          ...violations(file.path, file.readAsLinesSync()),
      ];
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

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
}
