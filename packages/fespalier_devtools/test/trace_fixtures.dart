// Records of the guards, the data and the actions, and the snapshots and events that carry them,
// for the tests of the controller and of the three panels that show them.
import 'package:fespalier_devtools/src/protocol.dart';

import 'fake_client.dart';

const _at = 1696230000000;

/// A guard decision. The default is `g6@7` of the features example, letting `/admin` through.
GuardRecord guardRecord(
  int seq, {
  String site = 'g6@7',
  String uri = '/admin',
  String result = GuardOutcome.pass,
  String? location,
  bool isAsync = false,
  int ms = 0,
  String? error,
}) => GuardRecord(
  seq: seq,
  at: _at + seq * 1000,
  site: site,
  uri: uri,
  fullPath: uri,
  result: result,
  location: location,
  isAsync: isAsync,
  ms: ms,
  error: error,
);

/// A data record. The default is `d40` of the features example, keyed by 2.
DataRecord dataRecord(
  int id, {
  String site = 'd40',
  Shown? key = const Shown('int', '2'),
  int container = 1,
  String state = DataState.data,
  int builds = 1,
  int created = _at,
  int? updated,
  Shown? value = const Shown('Refund', 'Refund(2)'),
  String? error,
  String via = DataVia.build,
  Shown? provider,
  int? listeners,
}) => DataRecord(
  id: id,
  site: site,
  key: key,
  container: container,
  state: state,
  builds: builds,
  created: created,
  updated: updated ?? created + 500,
  value: value,
  error: error,
  via: via,
  provider: provider,
  listeners: listeners,
);

/// An action run. The default is `a40_0` of the features example, called with an input.
ActionRecord actionRecord(
  int seq, {
  String site = 'a40_0',
  Shown? key = const Shown('int', '2'),
  Shown input = const Shown('RefundInput', 'RefundInput(5)'),
  String state = ActionState.done,
  int? ms = 120,
  Shown? result = const Shown('bool', 'true'),
  String? error,
}) => ActionRecord(
  seq: seq,
  site: site,
  key: key,
  input: input,
  state: state,
  started: _at + seq * 1000,
  ms: ms,
  result: result,
  error: error,
);

/// The catalog snapshot (event 7) with these lists, and [history] if it is given.
Map<String, Object?> tracedSnapshot({
  List<GuardRecord> guards = const [],
  List<DataRecord> data = const [],
  List<ActionRecord> actions = const [],
  List<NavigationRecord>? history,
  int event = 7,
}) => {
  ...fixture('snapshot_catalog'),
  'event': event,
  if (history != null) 'history': [for (final h in history) h.toJson()],
  'guards': [for (final g in guards) g.toJson()],
  'data': [for (final d in data) d.toJson()],
  'actions': [for (final a in actions) a.toJson()],
};

/// The payload of an event of number [number] that carries [record].
Map<String, Object?> recordEvent(int number, Map<String, Object?> record) => {
  'protocol': devToolsProtocol,
  DevToolsEventPayload.event: number,
  DevToolsEventPayload.record: record,
};
