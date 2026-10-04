/// The tags, contexts, span operations and data keys `fespalier_sentry` writes. The `fespalier.*`
/// names are the telemetry conventions' (contract version 1), so a search in Sentry and a query in
/// OpenObserve use the same words. How they map onto Sentry is documented with this package and
/// is not part of contract version 1.
library;

/// One declaration per name.
abstract final class SentryKeys {
  // Tags and span data (the conventions' names).

  /// The route pattern: `/products/:id`.
  static const String route = 'fespalier.route';

  /// The app file: `products/$id/data.dart`.
  static const String file = 'fespalier.file';

  /// Which kind of operation: `data`, `guard`, `action`, ...
  static const String operation = 'fespalier.operation';

  /// An action's function name.
  static const String action = 'fespalier.action';

  /// Whether the operation returned a `Future`.
  static const String isAsync = 'fespalier.async';

  /// Whether a data provider is a family.
  static const String keyed = 'fespalier.data.keyed';

  /// How a navigation happened, and how it ended.
  static const String navigationKind = 'fespalier.navigation.kind';

  /// How a navigation ended.
  static const String navigationOutcome = 'fespalier.navigation.outcome';

  /// The page that was on top before.
  static const String navigationFrom = 'fespalier.navigation.from';

  /// Whether a guard or a redirect sent the navigation elsewhere.
  static const String navigationRedirected = 'fespalier.navigation.redirected';

  /// How many pushed pages the stack holds after the commit.
  static const String navigationDepth = 'fespalier.navigation.depth';

  /// Where a navigation came from when the app's own code did not start it.
  static const String navigationSource = 'fespalier.navigation.source';

  /// The committed path, with `recordLocations`.
  static const String urlPath = 'url.path';

  /// What a guard decided.
  static const String guardDecision = 'fespalier.guard.decision';

  /// Where a guard redirected to, with `recordLocations`.
  static const String guardLocation = 'fespalier.guard.location';

  /// How a data load ended.
  static const String dataState = 'fespalier.data.state';

  /// How an action run ended.
  static const String actionResult = 'fespalier.action.result';

  /// How a deferred load ended.
  static const String deferredResult = 'fespalier.deferred.result';

  /// The step of an auth operation.
  static const String authOperation = 'fespalier.auth.operation';

  /// How an auth operation ended.
  static const String authResult = 'fespalier.auth.result';

  /// The auth backend's constant name.
  static const String authBackend = 'fespalier.auth.backend';

  /// What asked for a refresh.
  static const String authTrigger = 'fespalier.auth.trigger';

  /// Whether the backend binds its tokens with DPoP.
  static const String authDpop = 'fespalier.auth.dpop';

  /// The image URL builder's name.
  static const String imageCdn = 'fespalier.image.cdn';

  /// The width an image was asked for.
  static const String imageWidth = 'fespalier.image.width';

  /// Whether a precache started an image load.
  static const String imagePreload = 'fespalier.image.preload';

  /// How an image load ended.
  static const String imageResult = 'fespalier.image.result';

  /// The HTTP status of a failed image load.
  static const String imageStatus = 'fespalier.image.status';

  // The OpenTelemetry trace an event links to (`fespalier_otel` next to this sink).

  /// The trace id of the OpenTelemetry span of the screen or the call.
  static const String otelTraceId = 'otel.trace_id';

  /// The span id.
  static const String otelSpanId = 'otel.span_id';

  /// The context that holds both, next to the tags.
  static const String otelContext = 'otel';

  /// The context an event carries: operation, route, file, action, async and keyed.
  static const String fespalierContext = 'fespalier';

  // Sentry's own names.

  /// The transaction operation of a screen load.
  static const String uiLoad = 'ui.load';

  /// Time to initial display, as a span and as a measurement.
  static const String initialDisplayOp = 'ui.load.initial_display';

  /// Time to full display, as a span.
  static const String fullDisplayOp = 'ui.load.full_display';

  /// The measurement `SentryMeasurement.timeToInitialDisplay` writes.
  static const String ttidMeasurement = 'time_to_initial_display';

  /// The measurement `SentryMeasurement.timeToFullDisplay` writes.
  static const String ttfdMeasurement = 'time_to_full_display';

  /// The trace origin of a transaction this sink makes.
  static const String navigationOrigin = 'auto.navigation.fespalier';

  /// The transaction operation of an action that no screen transaction is open for.
  static const String actionOp = 'fespalier.action';

  /// The category of a page breadcrumb (Sentry's own, so its UI draws it as a navigation).
  static const String navigationCategory = 'navigation';
}
