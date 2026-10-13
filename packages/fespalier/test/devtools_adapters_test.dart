// What an adapter package shows in the Adapters tab (since 0.16.0): `DevToolsAdapters.show` and
// `hide`, the `adapter` event, the snapshot's `adapters`, and the `adapterEdit` method.
import 'dart:convert';

import 'package:fespalier/src/devtools/devtools.dart';
import 'package:fespalier/src/devtools/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// What a tool sees: the answer of `ext.fespalier.snapshot`.
Future<SnapshotRecord> snapshot() async =>
    SnapshotRecord.fromJson(await debugDevToolsCall(DevToolsMethods.snapshot));

List<(String, Map<String, Object?>)> get events => debugDevToolsEvents!;

/// The adapter events so far, as records.
List<AdapterRecord> adapterEvents() => [
  for (final e in events)
    if (e.$1 == DevToolsEvents.adapter)
      AdapterRecord.fromJson(e.$2['record']! as Map<String, Object?>),
];

Future<Map<String, Object?>> edit(String adapter, String key, String value) =>
    debugDevToolsCall(DevToolsMethods.adapterEdit, {
      'adapter': adapter,
      'key': key,
      'value': value,
    });

void main() {
  setUp(() {
    debugDevToolsReset();
    debugDevToolsEvents = [];
  });
  tearDown(() {
    debugDevToolsReset();
    debugDevToolsEvents = null;
  });

  group('show', () {
    test('posts the adapter event with the record, numbered', () {
      DevToolsAdapters.show('fespalier_flags', {
        'new_checkout': true,
        'limit': 3,
      }, title: 'Feature flags');
      expect([for (final e in events) e.$1], [DevToolsEvents.adapter]);
      final payload = events.single.$2;
      expect(payload['protocol'], 1);
      expect(payload['event'], 1);
      final record = AdapterRecord.fromJson(
        payload['record']! as Map<String, Object?>,
      );
      expect(record.adapter, 'fespalier_flags');
      expect(record.title, 'Feature flags');
      expect(record.removed, isFalse);
      expect(record.truncated, isFalse);
      expect(record.at, greaterThan(0));
      expect(
        [for (final v in record.values) (v.key, v.value, v.editable)],
        [
          ('new_checkout', const Shown('bool', 'true'), false),
          ('limit', const Shown('int', '3'), false),
        ],
      );
      expect(() => jsonEncode(payload), returnsNormally);
    });

    test(
      'shows a value as its type and the start of its text, made at once',
      () {
        final list = <int>[1, 2];
        DevToolsAdapters.show('a', {
          'list': list,
          'long': 'x' * 1000,
          'null': null,
          'throws': _Throws(),
        });
        list.add(3);
        final values = {
          for (final v in adapterEvents().single.values) v.key: v.value,
        };
        expect(values['list'], const Shown('List<int>', '[1, 2]'));
        expect(values['long']!.text, '${'x' * 200}…');
        expect(values['null'], const Shown('Null', 'null'));
        expect(values['throws'], const Shown('_Throws', shownThrew));
      },
    );

    test(
      'shows again in place of what it showed before, in the snapshot',
      () async {
        DevToolsAdapters.show('b', {'k': 1});
        DevToolsAdapters.show('a', {'k': 'x'});
        DevToolsAdapters.show('b', {'k': 2});
        final adapters = (await snapshot()).adapters;
        // By name, whatever the order they were shown in.
        expect([for (final a in adapters) a.adapter], ['a', 'b']);
        expect(adapters.last.values.single.value, const Shown('int', '2'));
        expect(adapters.last.seq, greaterThan(adapters.first.seq));
        expect(events, hasLength(3));
        expect((await snapshot()).event, 3);
      },
    );

    test('keeps the first 64 keys and says so', () async {
      DevToolsAdapters.show('big', {for (var i = 0; i < 100; i++) 'k$i': i});
      final record = (await snapshot()).adapters.single;
      expect(record.values, hasLength(64));
      expect(record.values.first.key, 'k0');
      expect(record.values.last.key, 'k63');
      expect(record.truncated, isTrue);
      DevToolsAdapters.show('exact', {for (var i = 0; i < 64; i++) 'k$i': i});
      expect(
        (await snapshot()).adapters.firstWhere((a) => a.adapter == 'exact'),
        isA<AdapterRecord>().having((a) => a.truncated, 'truncated', false),
      );
    });

    test('keeps 32 adapters, dropping the one shown least recently', () async {
      for (var i = 0; i < 32; i++) {
        DevToolsAdapters.show('a${i.toString().padLeft(2, '0')}', {'i': i});
      }
      // Showing a00 again makes a01 the least recent.
      DevToolsAdapters.show('a00', {'i': 100});
      expect(events, hasLength(33));
      DevToolsAdapters.show('b', {'i': 0});
      final names = [for (final a in (await snapshot()).adapters) a.adapter];
      expect(names, hasLength(32));
      expect(names, isNot(contains('a01')));
      expect(names, containsAll(['a00', 'a02', 'b']));
      // A tool that follows the events is told the one that went, then the new one.
      final told = adapterEvents();
      final dropped = told[told.length - 2];
      expect((dropped.adapter, dropped.removed), ('a01', true));
      expect(dropped.values, isEmpty);
      expect((told.last.adapter, told.last.removed), ('b', false));
    });

    test('before the app registered, still shows up in the snapshot', () async {
      DevToolsAdapters.show('early', {'k': 1});
      final snap = await snapshot();
      expect(snap.registered, isFalse);
      expect(snap.adapters.single.adapter, 'early');
    });
  });

  group('hide', () {
    test('removes the adapter and posts a removed record', () async {
      DevToolsAdapters.show('a', {'k': 1});
      DevToolsAdapters.show('b', {'k': 1});
      DevToolsAdapters.hide('a');
      expect([for (final a in (await snapshot()).adapters) a.adapter], ['b']);
      final last = adapterEvents().last;
      expect(
        (last.adapter, last.removed, last.values.isEmpty),
        ('a', true, true),
      );
      expect(events.last.$2['event'], 3);
    });

    test('an adapter that showed nothing posts nothing', () async {
      DevToolsAdapters.hide('nobody');
      expect(events, isEmpty);
      expect((await snapshot()).adapters, isEmpty);
    });
  });

  group('hello', () {
    test(
      'lists adapters, and the snapshot has the key with none shown',
      () async {
        final hello = HelloRecord.fromJson(
          await debugDevToolsCall(DevToolsMethods.hello),
        );
        expect(hello.features, contains(DevToolsFeatures.adapters));
        final json = await debugDevToolsCall(DevToolsMethods.snapshot);
        expect(json['adapters'], <Object?>[]);
      },
    );
  });

  group('adapterEdit', () {
    test('calls onEdit with the key and the text, once, and says ok', () async {
      final calls = <(String, String)>[];
      DevToolsAdapters.show(
        'fespalier_flags',
        {'new_checkout': 'on', 'limit': 3},
        editable: {'new_checkout'},
        onEdit: (key, text) => calls.add((key, text)),
      );
      expect(await edit('fespalier_flags', 'new_checkout', 'off'), {
        'protocol': 1,
        'ok': true,
      });
      expect(calls, [('new_checkout', 'off')]);
      final record = adapterEvents().single;
      expect(
        [for (final v in record.values) (v.key, v.editable)],
        [('new_checkout', true), ('limit', false)],
      );
    });

    test('takes an empty text, which is a value too', () async {
      String? got;
      DevToolsAdapters.show(
        'a',
        {'k': 'x'},
        editable: {'k'},
        onEdit: (_, text) => got = text,
      );
      expect((await edit('a', 'k', ''))['ok'], isTrue);
      expect(got, '');
      // A call with no `value` parameter at all is the empty text too.
      got = 'unset';
      await debugDevToolsCall(DevToolsMethods.adapterEdit, {
        'adapter': 'a',
        'key': 'k',
      });
      expect(got, '');
    });

    test('an adapter that is not shown is refused, with a reason', () async {
      expect(await edit('nobody', 'k', 'v'), {
        'protocol': 1,
        'ok': false,
        'reason': 'no adapter nobody is shown',
      });
      DevToolsAdapters.show('a', {'k': 1}, editable: {'k'}, onEdit: (_, _) {});
      DevToolsAdapters.hide('a');
      expect((await edit('a', 'k', 'v'))['reason'], 'no adapter a is shown');
    });

    test('a key that is not editable is refused, with a reason', () async {
      var called = false;
      DevToolsAdapters.show(
        'a',
        {'k': 1, 'ro': 2},
        editable: {'k', 'ghost'},
        onEdit: (_, _) => called = true,
      );
      expect(await edit('a', 'ro', 'v'), {
        'protocol': 1,
        'ok': false,
        'reason': '`ro` of a is not editable',
      });
      // A key the adapter named as editable but gave no value for is not there to edit.
      expect(
        (await edit('a', 'ghost', 'v'))['reason'],
        '`ghost` of a is not editable',
      );
      expect(
        (await edit('a', 'nope', 'v'))['reason'],
        '`nope` of a is not editable',
      );
      expect(called, isFalse);
    });

    test('without onEdit no key is editable', () async {
      DevToolsAdapters.show('a', {'k': 1}, editable: {'k'});
      expect(adapterEvents().single.values.single.editable, isFalse);
      expect((await edit('a', 'k', 'v'))['ok'], isFalse);
    });

    test('an onEdit that throws is an answer with the error', () async {
      DevToolsAdapters.show(
        'a',
        {'k': 1},
        editable: {'k'},
        onEdit: (_, _) => throw StateError('no flags yet'),
      );
      expect(await edit('a', 'k', 'v'), {
        'protocol': 1,
        'ok': false,
        'reason': 'onEdit threw: Bad state: no flags yet',
      });
    });

    test('a missing adapter or key is the usual missing parameter', () async {
      final noAdapter = await debugDevToolsCall(DevToolsMethods.adapterEdit, {
        'key': 'k',
      });
      expect(noAdapter['errorCode'], -32602);
      expect(noAdapter['errorDetail'], 'missing parameter `adapter`');
      final noKey = await debugDevToolsCall(DevToolsMethods.adapterEdit, {
        'adapter': 'a',
      });
      expect(noKey['errorDetail'], 'missing parameter `key`');
    });

    test('an onEdit that shows again posts the new values', () async {
      void onEdit(String key, String text) => DevToolsAdapters.show(
        'a',
        {key: text},
        editable: {key},
        onEdit: onEdit,
      );
      DevToolsAdapters.show('a', {'k': 'x'}, editable: {'k'}, onEdit: onEdit);
      await edit('a', 'k', 'y');
      expect(adapterEvents(), hasLength(2));
      expect(adapterEvents().last.values.single.value.text, 'y');
      expect((await snapshot()).adapters.single.values.single.value.text, 'y');
    });
  });

  group('what it costs', () {
    testWidgets('no frame is scheduled by showing, editing or hiding', (
      tester,
    ) async {
      DevToolsAdapters.show('a', {'k': 1}, editable: {'k'}, onEdit: (_, _) {});
      await edit('a', 'k', 'v');
      DevToolsAdapters.hide('a');
      await debugDevToolsCall(DevToolsMethods.snapshot);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    test(
      'with no spy and no tool listening, nothing is posted and nothing throws',
      () async {
        debugDevToolsEvents = null;
        DevToolsAdapters.show('a', {'k': 1});
        DevToolsAdapters.hide('a');
        DevToolsAdapters.show('b', {'k': 1});
        expect((await snapshot()).adapters.single.adapter, 'b');
        // The events nobody saw are counted, so a tool that connects later sees a gap.
        expect((await snapshot()).event, 3);
      },
    );
  });
}

class _Throws {
  @override
  String toString() => throw StateError('no');
}
