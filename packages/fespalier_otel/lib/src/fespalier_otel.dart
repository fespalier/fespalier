/// fespalier's telemetry as OpenTelemetry spans (since 0.8.1), on the SDK that `otel_zone` (or the
/// app) started.
library;

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:fespalier/fespalier.dart';
import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        defaultTargetPlatform,
        kIsWeb,
        kReleaseMode,
        visibleForTesting;

import 'conventions.dart';

/// fespalier's telemetry as OpenTelemetry spans, on the SDK that `otel_zone` (or the app) started
/// (since 0.8.1).
///
/// ```dart
/// FespalierTelemetry.install(FespalierOtel(isReady: () => observability.isReady));
/// ```
///
/// Nothing is emitted until [isReady] says the SDK is up (dartastic's entry points throw before
/// `OTel.initialize`), every SDK call is inside a `try`, and the adapter starts no timer and no
/// zone: a failure costs a span, never a feature. The names and attributes it emits are the
/// telemetry conventions, contract version 1 ([FespalierConventions]).
final class FespalierOtel extends FespalierTelemetry {
  /// [isReady] says whether the SDK is up: pass `() => observability.isReady` with `otel_zone`.
  /// Leave it out when the app initialises the SDK itself before installing this.
  ///
  /// [recordLocations] adds `url.path`, `url.query` and `fespalier.guard.location`: segment and
  /// query values are app data, so it is off.
  FespalierOtel({bool Function()? isReady, this.recordLocations = false})
    : _isReady = isReady;

  final bool Function()? _isReady;

  /// Whether spans carry the committed location (`url.path`, `url.query`) and where a guard
  /// redirected to (`fespalier.guard.location`).
  final bool recordLocations;

  Tracer? _tracer;

  /// What to merge into `otel_zone`'s `start(resourceAttributes:)`: the fespalier release and the
  /// version of the telemetry conventions.
  static const Map<String, String> resourceAttributes = {
    FespalierConventions.resourceVersion: fespalierVersion,
    FespalierConventions.resourceTelemetryVersion: FespalierConventions.version,
  };

  /// The OTLP/HTTP endpoint to export to, for `OtelZoneConfig.endpoint`.
  ///
  /// `--dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=...` (or `--dart-define-from-file`) wins.
  /// Without it, a debug or profile build points at a collector on this computer:
  /// `http://10.0.2.2:4318` on Android (the emulator's address for its host) and
  /// `http://localhost:4318` everywhere else (the iOS simulator, desktop, the web). A release
  /// build without the define gets `''`, which `otel_zone` takes as "telemetry off", so a store
  /// build never sends to a developer's computer.
  static String endpoint() => resolveEndpoint(
    defined: const String.fromEnvironment('OTEL_EXPORTER_OTLP_ENDPOINT'),
    platform: defaultTargetPlatform,
    isWeb: kIsWeb,
    isRelease: kReleaseMode,
  );

  /// [endpoint]'s rule with its inputs given, for tests.
  @visibleForTesting
  static String resolveEndpoint({
    required String defined,
    required TargetPlatform platform,
    required bool isWeb,
    required bool isRelease,
  }) {
    if (defined.isNotEmpty) return defined;
    if (isRelease) return '';
    if (!isWeb && platform == TargetPlatform.android) {
      return 'http://10.0.2.2:4318';
    }
    return 'http://localhost:4318';
  }

  /// The tracer, once the SDK is up; null before. Resolved on the first use and kept.
  Tracer? _resolve() {
    final cached = _tracer;
    if (cached != null) return cached;
    final ready = _isReady;
    if (ready != null && !ready()) return null;
    try {
      return _tracer = OTel.tracerProvider().getTracer(
        FespalierConventions.scope,
        version: fespalierVersion,
      );
    } catch (_) {
      // The SDK never started: try again at the next operation.
      return null;
    }
  }

  @override
  Object? start(TelemetryStart start) {
    try {
      final tracer = _resolve();
      if (tracer == null) return null;
      final site = start.site;
      final (name, attributes) = switch (start.op) {
        TelemetryOp.navigate => (
          FespalierConventions.opNavigate,
          <String, Object>{
            FespalierConventions.operation: FespalierConventions.opNavigate,
          },
        ),
        TelemetryOp.guard || TelemetryOp.redirect => (
          '${start.op.name} ${site?.file}',
          <String, Object>{
            FespalierConventions.operation: start.op.name,
            FespalierConventions.route: ?site?.route,
            FespalierConventions.file: ?site?.file,
          },
        ),
        TelemetryOp.data => (
          'data ${site?.file}',
          <String, Object>{
            FespalierConventions.operation: FespalierConventions.opData,
            FespalierConventions.route: ?site?.route,
            FespalierConventions.file: ?site?.file,
            FespalierConventions.dataKeyed: start.keyed,
          },
        ),
        TelemetryOp.action => (
          'action ${site?.file}#${site?.name}',
          <String, Object>{
            FespalierConventions.operation: FespalierConventions.opAction,
            FespalierConventions.route: ?site?.route,
            FespalierConventions.file: ?site?.file,
            FespalierConventions.actionName: ?site?.name,
          },
        ),
        TelemetryOp.deferred => (
          'deferred ${start.file}',
          <String, Object>{
            FespalierConventions.operation: FespalierConventions.opDeferred,
            FespalierConventions.route: ?start.route,
            FespalierConventions.file: ?start.file,
          },
        ),
        // Only the step, the backend's constant name, the trigger and whether tokens are bound:
        // never a token, an id, a claim, an e-mail or a URL.
        TelemetryOp.auth => (
          'auth ${start.authStep}',
          <String, Object>{
            FespalierConventions.operation: FespalierConventions.opAuth,
            FespalierConventions.authOperation: ?start.authStep,
            FespalierConventions.authBackend: ?start.authBackend,
            FespalierConventions.authTrigger: ?start.authTrigger,
            FespalierConventions.authDpop: start.authDpop,
          },
        ),
      };
      final parent = start.parent;
      final span = tracer.startSpan(
        name,
        // A navigation is a root span, whatever is current.
        context: start.op == TelemetryOp.navigate ? Context.root : null,
        parentSpan: parent is _Running ? parent.span : null,
        attributes: OTel.attributesFromMap(attributes),
      );
      return _Running(span, start.op);
    } catch (_) {
      return null;
    }
  }

  @override
  void end(Object? token, TelemetryEnd end) {
    if (token is! _Running) return;
    final span = token.span;
    try {
      _describe(token, end);
      final error = end.error;
      if (end.outcome == TelemetryOutcome.error &&
          error != null &&
          token.op == TelemetryOp.auth) {
        // An auth error's text may name a host or an endpoint: the class is all that is kept.
        span.setStringAttribute<String>(
          FespalierConventions.errorType,
          error.runtimeType.toString(),
        );
        span.setStatus(SpanStatusCode.Error);
      } else if (end.outcome == TelemetryOutcome.error && error != null) {
        span.setStringAttribute<String>(
          FespalierConventions.errorType,
          error.runtimeType.toString(),
        );
        span.recordException(error, stackTrace: end.stackTrace);
        span.setStatus(SpanStatusCode.Error, '$error');
      } else if (end.outcome == TelemetryOutcome.error) {
        span.setStatus(SpanStatusCode.Error);
      }
    } catch (_) {
      // A failing SDK costs this span's detail, never the app.
    } finally {
      try {
        span.end();
      } catch (_) {
        // Same.
      }
    }
  }

  /// Sets what [end] says on the span of the operation that [token] is.
  void _describe(_Running running, TelemetryEnd end) {
    final span = running.span;
    switch (running.op) {
      case TelemetryOp.navigate:
        _describeNavigation(span, end);
      case TelemetryOp.guard || TelemetryOp.redirect:
        span.setStringAttribute<String>(
          FespalierConventions.guardDecision,
          end.outcome,
        );
        span.setBoolAttribute(FespalierConventions.isAsync, end.isAsync);
        final location = end.location;
        if (recordLocations && location != null) {
          span.setStringAttribute<String>(
            FespalierConventions.guardLocation,
            location,
          );
        }
      case TelemetryOp.data:
        span.setStringAttribute<String>(
          FespalierConventions.dataState,
          end.outcome,
        );
        span.setBoolAttribute(FespalierConventions.isAsync, end.isAsync);
      case TelemetryOp.action:
        span.setStringAttribute<String>(
          FespalierConventions.actionResult,
          end.outcome,
        );
        span.setBoolAttribute(FespalierConventions.isAsync, end.isAsync);
      case TelemetryOp.deferred:
        span.setStringAttribute<String>(
          FespalierConventions.deferredResult,
          end.outcome,
        );
      case TelemetryOp.auth:
        span.setStringAttribute<String>(
          FespalierConventions.authResult,
          end.outcome,
        );
        span.setBoolAttribute(FespalierConventions.isAsync, end.isAsync);
    }
  }

  void _describeNavigation(Span span, TelemetryEnd end) {
    final route = end.route;
    span.updateName(switch (end.outcome) {
      TelemetryOutcome.notFound => FespalierConventions.spanNavigateNotFound,
      TelemetryOutcome.superseded => FespalierConventions.opNavigate,
      _ =>
        route == null
            ? FespalierConventions.opNavigate
            : '${FespalierConventions.opNavigate} $route',
    });
    span.setStringAttribute<String>(
      FespalierConventions.navigationOutcome,
      end.outcome,
    );
    if (route != null) {
      span.setStringAttribute<String>(FespalierConventions.route, route);
    }
    final kind = end.kind;
    if (kind != null) {
      span.setStringAttribute<String>(
        FespalierConventions.navigationKind,
        kind,
      );
    }
    final from = end.from;
    if (from != null) {
      span.setStringAttribute<String>(
        FespalierConventions.navigationFrom,
        from,
      );
    }
    if (end.outcome == TelemetryOutcome.superseded) return;
    span
      ..setBoolAttribute(
        FespalierConventions.navigationRedirected,
        end.redirected,
      )
      ..setIntAttribute(FespalierConventions.navigationDepth, end.depth);
    final location = end.location;
    if (recordLocations && location != null) {
      final uri = Uri.parse(location);
      span.setStringAttribute<String>(FespalierConventions.urlPath, uri.path);
      if (uri.query.isNotEmpty) {
        span.setStringAttribute<String>(
          FespalierConventions.urlQuery,
          uri.query,
        );
      }
    }
  }

  @override
  void page(Object? navigation, TelemetryPage page) {
    if (navigation is! _Running) return;
    try {
      final route = page.route;
      final duration = page.duration;
      navigation.span.addEventNow(
        switch (page.kind) {
          TelemetryPageKind.enter => FespalierConventions.eventEnter,
          TelemetryPageKind.focus => FespalierConventions.eventFocus,
          TelemetryPageKind.leave => FespalierConventions.eventLeave,
        },
        OTel.attributesFromMap({
          FespalierConventions.route: ?route,
          FespalierConventions.pageDuration:
              ?(page.kind == TelemetryPageKind.leave
              ? duration?.inMilliseconds
              : null),
        }),
      );
    } catch (_) {
      // Same as every call into the SDK.
    }
  }
}

/// A span being made, and what it is: the token this adapter hands fespalier.
final class _Running {
  _Running(this.span, this.op);

  final Span span;
  final TelemetryOp op;
}
