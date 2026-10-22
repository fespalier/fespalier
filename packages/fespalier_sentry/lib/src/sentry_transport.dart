// The span factory (`Hub.options.spanFactory`) and `InstrumentationSpan` are `@internal`, documented
// as "Instrumentation API for Sentry packages": `SentryHttpClient` and `sentry_dio` make their
// spans the same way, and it is what covers both trace lifecycles with one code path.
// ignore_for_file: invalid_use_of_internal_member
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:fespalier_transport/fespalier_transport.dart'
    show
        HttpTransport,
        TransportAborted,
        TransportFailure,
        TransportRequest,
        TransportRequestMemo,
        TransportResponse,
        TransportStatusError,
        TransportTimedOut,
        transportReplayKey;
import 'package:sentry_flutter/sentry_flutter.dart';

import 'keys.dart';
import 'spans.dart' show fire;

/// A transport that tells Sentry about each request it sends (since 0.21.0).
///
/// ```dart
/// final transport = SentryTransport(
///   WriteGuardTransport(HttpClientTransport(client)),
///   tracing: true,
///   tracePropagationTargets: [Uri.parse('https://api.example.com')],
/// );
/// ```
///
/// **Errors first**, like the rest of this package. By default a request leaves **one breadcrumb**
/// (category `http`: the method, the URL without its query and fragment, the status, how long it
/// took) and nothing else: no span, no header, no event. Sentry's breadcrumb trail is what makes an
/// error read as a story. With [captureFailedRequests] (default false, as Sentry's own) a request
/// that got no response (a `TransportFailure`, an abort excepted) or a `5xx` is also reported as an
/// error event. With [tracing] (the same opt-in as `FespalierSentry(tracing:)`, and it needs the
/// SDK's tracing on) each send is an `http.client` span, a child of the span that is active: the
/// `data` or `action` span in `traceLifecycle: stream`, the screen's transaction in `static`
/// (Sentry's static API cannot make a span current for a body). A re-send (an auth replay, a retry)
/// is a span of its own.
///
/// **Never recorded**: the query and the fragment (the span has `url.path`, the host and the
/// port), a header value (an `Authorization` included), a body, an error's text. `sentry-trace` and
/// `baggage` are added to a request only with [tracing] and only when its origin (scheme, host and
/// port) is one of [tracePropagationTargets]; the default is none. The request goes to [inner]
/// with the same `attributes` it came with (the auth replay mark, the `TransportMemo`).
///
/// Do not also put Sentry's own `SentryHttpClient` or `sentry_dio` on the same requests: each
/// request would be reported twice. It starts no timer and listens to nothing; a failing SDK costs
/// the report, never the request.
final class SentryTransport implements HttpTransport {
  /// A decorator over [inner]. [hub] defaults to the hub `SentryFlutter.init` started
  /// ([HubAdapter]).
  SentryTransport(
    this.inner, {
    Hub? hub,
    this.tracing = false,
    this.captureFailedRequests = false,
    Iterable<Uri> tracePropagationTargets = const <Uri>[],
  }) : _hub = hub ?? HubAdapter(),
       tracePropagationTargets = List<Uri>.unmodifiable(
         tracePropagationTargets,
       );

  /// What the request is sent through.
  final HttpTransport inner;

  /// Whether each send is an `http.client` span (and may carry trace headers).
  final bool tracing;

  /// Whether a failed request (no response, or a `5xx`) is also an error event.
  final bool captureFailedRequests;

  /// The origins that get `sentry-trace` and `baggage`, with [tracing].
  final List<Uri> tracePropagationTargets;

  final Hub _hub;

  static const String _sendsKey = 'fespalier.sentry.sends';

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    final started = clock.now();
    final url = _withoutQuery(request.uri);
    final resend = _resendCount(request);
    InstrumentationSpan? span;
    var outgoing = request;
    if (tracing) {
      try {
        span = _startSpan(request, url, resend);
        if (span != null && _propagates(request.uri)) {
          final added = <String, dynamic>{};
          addTracingHeadersToHttpHeader(added, _hub, span: span);
          outgoing = request.copyWith(
            headers: <String, String>{
              ...request.headers,
              for (final entry in added.entries) entry.key: '${entry.value}',
            },
          );
        }
      } catch (_) {
        // A failing SDK costs the span, never the request.
      }
    }

    final TransportResponse response;
    try {
      response = await inner.send(outgoing);
    } on Object catch (error) {
      _failed(span, request, url, started, error);
      rethrow;
    }
    _answered(span, request, url, started, response.statusCode);
    return response;
  }

  InstrumentationSpan? _startSpan(
    TransportRequest request,
    Uri url,
    int resend,
  ) {
    final factory = _hub.options.spanFactory;
    final parent = factory.getSpan(_hub);
    if (parent == null) return null;
    final method = request.method.toUpperCase();
    final span = factory.createSpan(
      parentSpan: parent,
      operation: SentryKeys.httpOp,
      description: '$method ${url.path.isEmpty ? '/' : url.path}',
    );
    if (span == null) return null;
    span
      ..origin = SentryKeys.httpOrigin
      ..setData(SentryKeys.operation, 'http')
      ..setData('http.request.method', method)
      ..setData('url.path', url.path.isEmpty ? '/' : url.path)
      ..setData('url.scheme', url.scheme)
      ..setData('server.address', url.host);
    final port = _portOf(url);
    if (port != null) span.setData('server.port', port);
    if (resend > 0) span.setData('http.request.resend_count', resend);
    return span;
  }

  void _answered(
    InstrumentationSpan? span,
    TransportRequest request,
    Uri url,
    DateTime started,
    int status,
  ) {
    try {
      if (span != null) {
        span
          ..setData('http.response.status_code', status)
          ..status = SpanStatus.fromHttpStatusCode(status);
        fire(span.finish());
      }
      fire(
        _hub.addBreadcrumb(
          Breadcrumb.http(
            url: url,
            method: request.method.toUpperCase(),
            statusCode: status,
            requestDuration: clock.now().difference(started),
            level: status >= 400 ? SentryLevel.error : SentryLevel.info,
          ),
        ),
      );
      if (captureFailedRequests && status >= 500) {
        _capture(
          TransportStatusError(
            statusCode: status,
            headers: const <String, String>{},
            body: Uint8List(0),
          ),
          request,
          url,
        );
      }
    } catch (_) {
      // A failing SDK costs the report, never the request.
    }
  }

  void _failed(
    InstrumentationSpan? span,
    TransportRequest request,
    Uri url,
    DateTime started,
    Object error,
  ) {
    try {
      if (span != null) {
        span
          ..throwable = error
          ..status = switch (error) {
            TransportAborted() => SpanStatus.cancelled(),
            TransportTimedOut() => SpanStatus.deadlineExceeded(),
            _ => SpanStatus.internalError(),
          };
        fire(span.finish());
      }
      fire(
        _hub.addBreadcrumb(
          Breadcrumb.http(
            url: url,
            method: request.method.toUpperCase(),
            // The class alone: the text of a failure names the host.
            reason: error.runtimeType.toString(),
            requestDuration: clock.now().difference(started),
            level: SentryLevel.error,
          ),
        ),
      );
      if (captureFailedRequests &&
          error is TransportFailure &&
          error is! TransportAborted) {
        _capture(error, request, url);
      }
    } catch (_) {
      // A failing SDK costs the report, never the request.
    }
  }

  void _capture(Object error, TransportRequest request, Uri url) {
    fire(
      _hub.captureEvent(
        SentryEvent(
          throwable: error,
          level: SentryLevel.error,
          tags: const <String, String>{SentryKeys.operation: 'http'},
          request: SentryRequest(
            url: url.toString(),
            method: request.method.toUpperCase(),
          ),
        ),
        stackTrace: StackTrace.current,
      ),
    );
  }

  // How many times this logical request was sent before: the memo counts sends when the client
  // keeps one, else an auth replay is one.
  static int _resendCount(TransportRequest request) {
    final memo = request.memo;
    if (memo != null) {
      final sends = memo.putIfAbsent<_Sends>(_sendsKey, _Sends());
      return sends.next();
    }
    return request.attributes[transportReplayKey] == true ? 1 : 0;
  }

  /// [uri] without its user info, query and fragment.
  static Uri _withoutQuery(Uri uri) => Uri(
    scheme: uri.scheme.isEmpty ? null : uri.scheme,
    host: uri.host.isEmpty ? null : uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
  );

  static int? _portOf(Uri uri) {
    if (uri.hasPort) return uri.port;
    return switch (uri.scheme) {
      'https' => 443,
      'http' => 80,
      _ => null,
    };
  }

  bool _propagates(Uri uri) {
    for (final origin in tracePropagationTargets) {
      if (origin.scheme == uri.scheme &&
          origin.host == uri.host &&
          _portOf(origin) == _portOf(uri)) {
        return true;
      }
    }
    return false;
  }
}

final class _Sends {
  int _count = 0;

  /// How many sends came before this one; counts it.
  int next() => _count++;
}
