import 'dart:async';

import 'package:fespalier/fespalier.dart' show Provider;

import 'lww.dart';

/// A row the server refused to take.
final class RowRejection {
  /// A refusal of the row [id] of [collection] for [code].
  const RowRejection({
    required this.collection,
    required this.id,
    required this.code,
    this.server,
  });

  /// The row's collection.
  final String collection;

  /// The row's id.
  final String id;

  /// The wire code only. The server's message is never kept: it may quote values.
  final String code;

  /// The server's current version of the row, if it has one: the device rolls back to it. Without
  /// one (a row the server never accepted) the local row is dropped.
  final OwnedRow? server;
}

/// What a push got back.
final class PushResult {
  /// A result.
  const PushResult({this.accepted = const [], this.rejected = const []});

  /// The rows the server took, as it now has them (the merged truth, with every field's stamp).
  final List<OwnedRow> accepted;

  /// The rows it refused.
  final List<RowRejection> rejected;
}

/// A page of rows changed since a cursor.
final class PullPage {
  /// A page.
  const PullPage(this.rows, {this.nextCursor, this.hasMore = false});

  /// The rows, with every field's stamp.
  final List<OwnedRow> rows;

  /// Where the next pull starts; saved after the page is applied.
  final String? nextCursor;

  /// Whether another page follows right away.
  final bool hasMore;
}

/// How dirty rows reach the server and others' changes come back.
///
/// CrateStack has no sync protocol of its own: the app implements this over two procedures in its
/// `.cstack` (say `syncPush` and `syncPull`), whose server side merges with the same per-field rule
/// and writes through the model layer, so policies still apply.
abstract interface class RowSync {
  /// Sends [dirty] rows. Throws what the client throws; `CrateStackErrors` classifies it.
  Future<PushResult> push(List<OwnedRow> dirty);

  /// The rows of [collection] changed since [cursor] (null: all of them).
  Future<PullPage> pull(String collection, String? cursor);
}

/// The app's [RowSync]; null when it has no owned rows (intents only).
final rowSync = Provider<RowSync?>((ref) => null);

/// The collections the sync engine pulls and pushes.
final syncCollections = Provider<List<String>>((ref) => const []);
