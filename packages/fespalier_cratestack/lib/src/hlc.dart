import 'dart:math' as math;

import 'package:clock/clock.dart';

/// A hybrid logical clock stamp: wall milliseconds (`clock.now()`), a counter, and the node id.
///
/// Stamps are totally ordered, comparing as (millis, counter, node), so two devices that edit the
/// same field are always ordered the same way. A stamp is causal, not wall-clock "latest": a
/// device whose clock is wrong cannot make a later edit lose to an earlier one it has already
/// seen, because [Hlc.receive] moves the local clock past every stamp that arrives.
final class Hlc implements Comparable<Hlc> {
  /// A stamp.
  const Hlc(this.millis, this.counter, this.node);

  /// The next stamp after [last] on this node: monotonic even when the wall clock steps back.
  factory Hlc.next(Hlc? last, String node) {
    final now = clock.now().millisecondsSinceEpoch;
    if (last == null || now > last.millis) return Hlc(now, 0, node);
    return Hlc(last.millis, last.counter + 1, node);
  }

  /// [last] advanced past a [remote] stamp that arrived: the result is later than both.
  factory Hlc.receive(Hlc? last, Hlc remote, String node) {
    final now = clock.now().millisecondsSinceEpoch;
    final mine = last?.millis ?? 0;
    final millis = math.max(now, math.max(mine, remote.millis));
    final mineCounter = last?.counter ?? 0;
    if (millis == mine && millis == remote.millis) {
      return Hlc(millis, math.max(mineCounter, remote.counter) + 1, node);
    }
    if (millis == mine) return Hlc(millis, mineCounter + 1, node);
    if (millis == remote.millis) return Hlc(millis, remote.counter + 1, node);
    return Hlc(millis, 0, node);
  }

  /// The wall-clock milliseconds since the epoch.
  final int millis;

  /// Orders stamps with the same [millis].
  final int counter;

  /// The device that made it.
  final String node;

  /// The stamp as text that also sorts as text: `<millis>-<counter in hex>-<node>`.
  String pack() =>
      '${millis.toString().padLeft(15, '0')}-${counter.toRadixString(16).padLeft(4, '0')}-$node';

  /// The stamp [pack] wrote. Throws a [FormatException] for anything else.
  static Hlc parse(String text) {
    final first = text.indexOf('-');
    final second = first < 0 ? -1 : text.indexOf('-', first + 1);
    if (second < 0) throw FormatException('not a packed Hlc', text);
    return Hlc(
      int.parse(text.substring(0, first)),
      int.parse(text.substring(first + 1, second), radix: 16),
      text.substring(second + 1),
    );
  }

  @override
  int compareTo(Hlc other) {
    final byMillis = millis.compareTo(other.millis);
    if (byMillis != 0) return byMillis;
    final byCounter = counter.compareTo(other.counter);
    if (byCounter != 0) return byCounter;
    return node.compareTo(other.node);
  }

  /// Whether this stamp is later than [other].
  bool operator >(Hlc other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is Hlc &&
      other.millis == millis &&
      other.counter == counter &&
      other.node == node;

  @override
  int get hashCode => Object.hash(millis, counter, node);

  @override
  String toString() => pack();
}
