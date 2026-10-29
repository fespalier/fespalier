// Since 0.25.0 the change feed is fespalier_stream's and fespalier_frb re-exports it: the same
// declarations, so a value made through one library is of the other's type (checked by the
// compiler: an assignment between the prefixed types would not compile for two classes of one
// name), and an app that imports both libraries meets no ambiguous name. ChangeCodec stays
// fespalier_frb's own facade over EventCodec.
import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_frb/fespalier_frb.dart' as frb;
import 'package:fespalier_frb/testing.dart' as frb_testing;
import 'package:fespalier_stream/fespalier_stream.dart' as stream;
import 'package:fespalier_stream/testing.dart' as stream_testing;
import 'package:flutter_test/flutter_test.dart';

// Both libraries without a prefix: a name both export would be an "ambiguous import" error here.
import 'package:fespalier_frb/fespalier_frb.dart';
import 'package:fespalier_stream/fespalier_stream.dart';

void main() {
  test('the moved names are the same declarations', () {
    final source = frb_testing.FakeChangeSource<int>();
    final stream_testing.FakeChangeSource<int> same = source;
    final frb.ChangeFeed<int> feed = stream.ChangeFeed<int>(
      (ref) => same.stream,
    );
    final stream.ChangeFeed<int> back = feed;
    final stream.ChangeTopic<int, int> topic = feed.topic<int>(
      (event, key) => event == key,
    );
    final frb.ChangeTopic<int, int> topicBack = topic;
    final frb.ChangeBudget budget = stream.ChangeBudget(_tick);
    final stream.ChangeBudget budgetBack = budget;
    const frb.Change<int> change = stream.Change<int>(1, 1);
    const stream.Change<int> changeBack = change;
    final frb.InvalidationTable<int> table = stream.InvalidationTable<int>([
      stream.InvalidationRule<int>((_) => true, (_) => const []),
    ]);
    final stream.InvalidationTable<int> tableBack = table;
    const Object unknown = frb.UnknownChange();
    expect(unknown, isA<stream.UnknownChange>());
    expect(frb.changeLogCapacity, stream.changeLogCapacity);
    expect([
      back,
      topicBack,
      budgetBack,
      changeBack,
      tableBack,
    ], everyElement(isNotNull));
  });

  test('both libraries together name each thing once', () {
    // Unprefixed: these resolve, so neither library hides a name of the other.
    final feed = ChangeFeed<int>(
      (ref) => const Stream<int>.empty(),
      name: 'changes',
    );
    final codec = ChangeCodec<String, int>(int.parse);
    final events = EventCodec<String, int>(int.parse);
    expect(feed, isA<stream.ChangeFeed<int>>());
    expect(codec, isA<StreamTransformer<String, int>>());
    expect(events, isA<StreamTransformer<String, int>>());
    expect(frbDecodeOp, isNot(FespalierStreamConventions.decode));
  });

  test('ChangeCodec keeps its members over EventCodec', () async {
    final skipped = <Object>[];
    final codec = frb.ChangeCodec<String, int>(
      (raw) => raw == 'new' ? throw const frb.UnknownChange() : int.parse(raw),
      onSkipped: (reason, _) => skipped.add(reason),
    );
    expect(codec.decode('1'), [1]);
    expect(codec.decode('x'), isEmpty);
    expect(codec.decode('new'), isEmpty);
    expect(codec.errorCount, 1);
    expect(codec.unknownCount, 1);
    expect(codec.onSkipped, isNotNull);
    expect(skipped, [isA<FormatException>(), isA<frb.UnknownChange>()]);
    final decoded = await Stream<String>.fromIterable([
      '2',
      'x',
      '3',
    ]).transform(codec).toList();
    expect(decoded, [2, 3]);
    final batch = frb.ChangeCodec.batch<String, String, int>(
      (raw) => raw.split(','),
      int.parse,
    );
    expect(batch.decode('4,y,5'), [4, 5]);
    expect(batch.errorCount, 1);
  });
}

final _tick = Provider<int>((ref) => 0);
