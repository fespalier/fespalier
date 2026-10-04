import 'package:fespalier/fespalier.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// What a navigation makes in Sentry.
enum NavKind {
  /// Nothing but the scope's route name and tag, and a breadcrumb: every navigation without
  /// `tracing: true`, and a pop or a refresh with it (they reveal a page that is already built).
  light,

  /// A `ui.load` transaction of its own, named by the route pattern (`tracing: true`).
  transaction,

  /// The first screen on Android and iOS, whose `ui.load` is Sentry's own app start.
  appStart,

  /// `transactions: false`: a `SentryNavigatorObserver` makes the transaction.
  observer,
}

/// The token of a navigation: what [FespalierTelemetry] hands back to `end`, `page` and, for what
/// runs during it, as the parent.
final class NavToken {
  /// A navigation of [kind], with its [tx] when it makes one.
  NavToken(this.kind, [this.tx]);

  /// What it makes in Sentry.
  final NavKind kind;

  /// Its transaction, for [NavKind.transaction].
  final ISentrySpan? tx;

  /// The OpenTelemetry span of this navigation, when `fespalier_otel` runs next to this sink.
  TelemetryTrace? trace;

  /// The data loads that started during it and have not ended.
  int openData = 0;

  /// Whether its own end was reported: it waits for its data only.
  bool ended = false;

  /// Whether it ended with a page on screen (outcome `ok`).
  bool shown = false;

  /// What the screen is called once it is known: the pattern, or `navigate (not found)`.
  String name = 'navigate';

  /// The display to report time to full display to, for [NavKind.appStart] and
  /// [NavKind.observer], taken when the navigation ended.
  SentryDisplay? display;

  /// The data spans still open, to finish with a deadline when the next navigation starts first.
  final List<OpToken> open = [];
}

/// The token of an operation other than a navigation.
final class OpToken {
  /// An operation that started as [start]; [span] is what it made in Sentry, if anything.
  OpToken(this.start, {this.span, this.screen, this.ownsTransaction = false});

  /// What started.
  final TelemetryStart start;

  /// The span (or, for an action, the transaction) it made, with `tracing: true`.
  final ISentrySpan? span;

  /// The navigation a data load belongs to.
  final NavToken? screen;

  /// Whether [span] is a transaction this operation made (an action that no screen was open for).
  final bool ownsTransaction;

  /// The OpenTelemetry span of this operation, when `fespalier_otel` runs next to this sink.
  TelemetryTrace? trace;

  /// Whether its end was reported: a data span that a deadline finished is not finished twice.
  bool done = false;

  /// Whether it counts in its screen's open data loads (`tracing: true`).
  bool counted = false;
}
