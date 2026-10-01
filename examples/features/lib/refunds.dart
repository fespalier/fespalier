import 'package:fespalier/fespalier.dart';

/// What the refund form sends.
class RefundInput {
  const RefundInput({required this.amount});

  final int amount;
}

/// What a refund answers with.
class Refund {
  const Refund({required this.id, required this.amount});

  final int id;
  final int amount;
}

/// A refund the server turned down; the form shows it, the page stays.
class RefundDeclined implements Exception {
  const RefundDeclined(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// A stand-in for the orders API: order `n` was paid `n * 10` EUR, and what was refunded
/// is gone from it. The tests give it a [gate] to hold a refund pending without a timer.
class RefundServer {
  RefundServer({this.gate});

  /// A refund waits for this before it answers, when there is one.
  final Future<void>? gate;

  final Map<int, int> _refunded = {};

  /// How many refunds were asked of it, failed ones included.
  int attempts = 0;

  /// What can still be refunded of an order.
  int left(int id) => id * 10 - (_refunded[id] ?? 0);

  Future<Refund> refund(int id, RefundInput input) async {
    attempts++;
    await gate;
    if (input.amount <= 0 || input.amount > left(id)) {
      throw RefundDeclined('Declined: at most ${left(id)} EUR');
    }
    _refunded[id] = (_refunded[id] ?? 0) + input.amount;
    return Refund(id: id, amount: input.amount);
  }
}

/// The server the app talks to; tests override it.
final refundServerProvider = Provider<RefundServer>((ref) => RefundServer());

/// Who is in each team, so that adding a member changes what `teams/$teamId/data.dart` reads.
class Roster {
  final Map<String, List<String>> _members = {};

  List<String> of(String teamId) =>
      List.of(_members.putIfAbsent(teamId, () => ['ann', 'bob']));

  void add(String teamId, String name) =>
      _members.putIfAbsent(teamId, () => ['ann', 'bob']).add(name);
}

final rosterProvider = Provider<Roster>((ref) => Roster());
