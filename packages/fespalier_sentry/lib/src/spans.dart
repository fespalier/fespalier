import 'dart:async';

import 'package:sentry_flutter/sentry_flutter.dart';

/// [result] of an SDK call, fired and forgotten: an error of the SDK is dropped, so none is ever
/// unhandled.
void fire(Object? result) {
  if (result is Future<Object?>) {
    unawaited(result.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  }
}

/// One span the sink made in Sentry, whatever API made it. Every call fires and forgets: it never
/// returns a `Future` and the SDK's errors never reach the sink's caller.
abstract interface class SpanHandle {
  /// Whether it ended.
  bool get finished;

  /// Sets the attribute [key] to [value]: the conventions' keys, never an app value.
  void set(String key, Object value);

  /// Sets the tag [key] to [value] (an attribute, where the API has no tags).
  void tag(String key, String value);

  /// A child of this span, for the operation [op] and described by [description].
  SpanHandle child(String op, String description);

  /// Ends it with [status]. A span of the streaming API has only ok and error, so it reads [failed]
  /// alone: whether the operation failed, or its deadline passed.
  void finish(SpanStatus status, {bool failed = false});

  /// Whether [scope] holds this very span as its current one.
  bool boundTo(Scope scope);

  /// Makes this span the one an event captured with [scope] belongs to.
  void attachTo(Scope scope);
}

/// The span of a screen: a `ui.load` transaction, with its time to initial and to full display.
abstract interface class ScreenSpan implements SpanHandle {
  /// Tells the screen its name, the route pattern, once the navigation knows it. A transaction is
  /// named through the scope; a streamed segment is named here, and spans of it that ended before
  /// the name was known end now, so that each carries the segment's name.
  void named(String name);

  /// Reports time to initial display: a child span from the start of the screen to now, and its
  /// measurement. [name] is the screen's.
  void initialDisplay(String name);

  /// Reports time to full display: a child span from the start of the screen to now, ended with
  /// the deadline status and no measurement when [deadline], else ok, with its measurement.
  void fullDisplay(String name, {required bool deadline});
}

/// Where the sink's spans are made: one implementation per way the SDK offers to make them.
abstract interface class Spans {
  /// The span bound to the SDK's current scope (a transaction, or the observer's), if any.
  SpanHandle? active();

  /// Whether [scope] has no span bound to it.
  bool unbound(Scope scope);

  /// Starts the transaction of a screen, named `navigate` until the route is known, and binds it
  /// to the scope.
  ScreenSpan startScreen();

  /// Starts a transaction called [name] for an action no screen was open for, and binds it to the
  /// scope.
  SpanHandle startAction(String name);

  /// Whether the span of a data load or an action is made around the code it runs ([runIn]), so
  /// that the spans the SDK's own integrations make there (an HTTP client's) are its children:
  /// `traceLifecycle: stream` only (since 0.19.0). A transaction cannot be made current for a
  /// body without binding it to the one global scope, which two loads at once would share.
  bool get runsInside;

  /// The time on the SDK's own clock.
  DateTime now();

  /// Makes a span described by [op] and [description], a child of [parent] or, with none, a
  /// segment of its own, and calls [inside] with it, once and synchronously, with the span current
  /// for the zone [inside] runs in. It starts at [startedAt] when given.
  ///
  /// The span stays open until the handle's `finish`: the SDK's own end, when [inside] returns,
  /// is held back until then, so that the sink's outcome, attributes and end time are the span's.
  /// Only called when [runsInside] is true.
  void runIn({
    required SpanHandle? parent,
    required String op,
    required String description,
    required DateTime? startedAt,
    required void Function(SpanHandle span) inside,
  });
}
