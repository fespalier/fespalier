// Per-field last-writer-wins: two devices converge whatever the order, and a read never
// overwrites an unpushed edit.
import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

OwnedRow row(
  Map<String, (Object?, int)> fields, {
  String node = 'a',
  Set<String> dirty = const {},
  String id = 'r1',
}) => OwnedRow(
  collection: 'notes',
  id: id,
  fields: {for (final e in fields.entries) e.key: e.value.$1},
  stamps: {for (final e in fields.entries) e.key: Hlc(e.value.$2, 0, node)},
  dirty: {...dirty},
);

/// What must converge: fields and stamps (dirty is the replica's own).
String shape(OwnedRow r) => jsonEncode({
  for (final k in r.fields.keys.toList()..sort())
    k: [r.fields[k], r.stamps[k]?.pack()],
});

OwnedRow randomRow(Random random, String node) {
  final fields = <String, (Object?, int)>{};
  for (final name in ['title', 'body', 'done', 'deletedAt']) {
    if (random.nextBool()) {
      fields[name] = ('$node${random.nextInt(100)}', 1 + random.nextInt(6));
    }
  }
  return row(fields, node: node);
}

void main() {
  test('different fields on two devices: both survive', () {
    final a = row({'title': ('A', 5)}, node: 'a');
    final b = row({'body': ('B', 6)}, node: 'b');
    final merged = LwwMerge.merge(a, b);
    expect(merged.fields, {'title': 'A', 'body': 'B'});
  });

  test('the same field: the greater stamp wins, in either order', () {
    final a = row({'title': ('A', 5)}, node: 'a');
    final b = row({'title': ('B', 6)}, node: 'b');
    expect(LwwMerge.merge(a, b).fields['title'], 'B');
    expect(LwwMerge.merge(b, a).fields['title'], 'B');
  });

  test('the same stamp from two nodes is ordered by the node', () {
    final a = row({'title': ('A', 5)}, node: 'a');
    final b = row({'title': ('B', 5)}, node: 'b');
    expect(shape(LwwMerge.merge(a, b)), shape(LwwMerge.merge(b, a)));
  });

  test('commutative, associative and idempotent over seeded random edits', () {
    final random = Random(7);
    for (var i = 0; i < 300; i++) {
      final a = randomRow(random, 'a');
      final b = randomRow(random, 'b');
      final c = randomRow(random, 'c');
      expect(
        shape(LwwMerge.merge(a, b)),
        shape(LwwMerge.merge(b, a)),
        reason: 'commutative $i',
      );
      expect(
        shape(LwwMerge.merge(LwwMerge.merge(a, b), c)),
        shape(LwwMerge.merge(a, LwwMerge.merge(b, c))),
        reason: 'associative $i',
      );
      expect(shape(LwwMerge.merge(a, a)), shape(a), reason: 'idempotent $i');
      final ab = LwwMerge.merge(a, b);
      expect(shape(LwwMerge.merge(ab, b)), shape(ab), reason: 'absorbs $i');
    }
  });

  test('a tombstone and a concurrent edit of another field both survive', () {
    final deleted = row({'deletedAt': ('2026-03-01', 7)}, node: 'a');
    final edited = row({'title': ('new', 6)}, node: 'b');
    for (final merged in [
      LwwMerge.merge(deleted, edited),
      LwwMerge.merge(edited, deleted),
    ]) {
      expect(merged.deleted, isTrue);
      expect(merged.fields['title'], 'new');
    }
  });

  test('a later write of deletedAt (null) brings the row back', () {
    final deleted = row({'deletedAt': ('2026-03-01', 7)}, node: 'a');
    final restored = row({'deletedAt': (null, 8)}, node: 'b');
    expect(LwwMerge.merge(deleted, restored).deleted, isFalse);
  });

  group('adopt', () {
    test(
      'a dirty field keeps the local edit against an older server stamp',
      () {
        final local = row({'title': ('mine', 9)}, dirty: {'title'});
        final server = row({'title': ('theirs', 5)}, node: 'b');
        final out = LwwMerge.adopt(local, server);
        expect(out.fields['title'], 'mine');
        expect(out.dirty, {'title'});
      },
    );

    test('a dirty field gives way to a newer server stamp, and is clean', () {
      final local = row({'title': ('mine', 5)}, dirty: {'title'});
      final server = row({'title': ('theirs', 9)}, node: 'b');
      final out = LwwMerge.adopt(local, server);
      expect(out.fields['title'], 'theirs');
      expect(out.dirty, isEmpty);
    });

    test(
      'an acknowledged edit (the server has the same stamp) becomes clean',
      () {
        final local = row({'title': ('mine', 5)}, dirty: {'title'});
        final server = row({'title': ('mine', 5)});
        expect(LwwMerge.adopt(local, server).dirty, isEmpty);
      },
    );

    test('clean fields take the server\'s, and local-only fields stay', () {
      final local = row(
        {'title': ('old', 5), 'draft': ('x', 6)},
        dirty: {'draft'},
      );
      final server = row({'title': ('new', 7), 'body': ('b', 7)}, node: 'b');
      final out = LwwMerge.adopt(local, server);
      expect(out.fields, {'title': 'new', 'draft': 'x', 'body': 'b'});
      expect(out.dirty, {'draft'});
    });
  });

  group('two devices through OwnedRows', () {
    OwnedRows device(InMemoryLocalStore store) {
      final container = containerFor(store: store);
      return container.read(ownedRows);
    }

    test('edits on different fields converge in either import order', () async {
      final a = device(InMemoryLocalStore());
      final b = device(InMemoryLocalStore());
      await withClock(Clock.fixed(epoch), () async {
        await a.edit('notes', 'n1', {'title': 'from A'});
        await b.edit('notes', 'n1', {'body': 'from B'});
      });
      final fromA = (await a.get('notes', 'n1'))!;
      final fromB = (await b.get('notes', 'n1'))!;
      final c1 = device(InMemoryLocalStore());
      final c2 = device(InMemoryLocalStore());
      await c1.adopt([fromA]);
      await c1.adopt([fromB]);
      await c2.adopt([fromB]);
      await c2.adopt([fromA]);
      final one = (await c1.get('notes', 'n1'))!;
      final two = (await c2.get('notes', 'n1'))!;
      expect(one.fields, {'title': 'from A', 'body': 'from B'});
      expect(shape(one), shape(two));
    });

    test(
      'the same field: the causally later edit wins on both devices',
      () async {
        final a = device(InMemoryLocalStore());
        final b = device(InMemoryLocalStore());
        await withClock(
          Clock.fixed(epoch),
          () => a.edit('notes', 'n1', {'title': 'first'}),
        );
        final fromA = (await a.get('notes', 'n1'))!;
        // B has seen A's edit, so its clock is past it, whatever B's wall clock says.
        await withClock(
          Clock.fixed(epoch.subtract(const Duration(hours: 1))),
          () async {
            await b.adopt([fromA]);
            await b.edit('notes', 'n1', {'title': 'second'});
          },
        );
        final fromB = (await b.get('notes', 'n1'))!;
        await a.adopt([fromB]);
        expect((await a.get('notes', 'n1'))!.fields['title'], 'second');
        expect((await a.get('notes', 'n1'))!.dirty, isEmpty);
      },
    );

    test(
      'a read never overwrites an unpushed edit with an older stamp',
      () async {
        final a = device(InMemoryLocalStore());
        final old = row({'title': ('server', 1)}, node: 'b');
        await withClock(
          Clock.fixed(epoch),
          () => a.edit('notes', 'n1', {'title': 'mine'}),
        );
        await a.adopt([old]);
        final out = (await a.get('notes', 'n1'))!;
        expect(out.fields['title'], 'mine');
        expect(out.dirty, {'title'});
      },
    );

    test(
      'remove writes a tombstone that is a dirty field; list hides it',
      () async {
        final a = device(InMemoryLocalStore());
        await a.edit('notes', 'n1', {'title': 't'});
        final removed = await a.remove('notes', 'n1');
        expect(removed.deleted, isTrue);
        expect(removed.dirty, contains(tombstoneField));
        expect(await a.list('notes'), isEmpty);
        expect(await a.list('notes', includeDeleted: true), hasLength(1));
      },
    );

    test('the node id is made once per store and kept', () async {
      final store = InMemoryLocalStore();
      final first = await device(store).node();
      final second = await device(store).node();
      expect(first, second);
      expect(first, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(await device(InMemoryLocalStore()).node(), isNot(first));
    });

    test('a synchronous store answers synchronously', () {
      final a = device(InMemoryLocalStore());
      final edited = a.edit('notes', 'n1', {'title': 't'});
      expect(edited, isA<OwnedRow>());
      expect(a.get('notes', 'n1'), isA<OwnedRow>());
      expect(a.list('notes'), isA<List<OwnedRow>>());
    });

    test('an edit bumps the collection revision', () async {
      final container = containerFor();
      await container.read(ownedRows).edit('notes', 'n1', {'title': 't'});
      expect(container.read(crateStackRevision('notes')), 1);
    });

    test('nobody signed in is the app\'s mistake, said plainly', () {
      final a = containerFor(scope: null).read(ownedRows);
      expect(() => a.get('notes', 'n1'), throwsStateError);
    });
  });
}
