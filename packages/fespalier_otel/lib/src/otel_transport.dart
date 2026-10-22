import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:fespalier/fespalier.dart' show fespalierVersion;
import 'package:fespalier_transport/fespalier_transport.dart'
    show
        HttpTransport,
        TransportRequest,
        TransportRequestMemo,
        TransportResponse,
        transportReplayKey;

import 'conventions.dart';

/// A transport that makes one OpenTelemetry `CLIENT` span for each request it sends (since
/// 0.21.0), on the SDK that `otel_zone` (or the app) started.
///
/// ```dart
/// final transport = OtelTransport(
///   WriteGuardTransport(HttpClientTransport(client)),
///   isReady: () => observability.isReady,
///   propagateTo: [Uri.parse('https://api.example.com')],
/// );
/// ```
///
/// The span is named by the method (`GET`), as OpenTelemetry's HTTP semantic conventions have it,
/// and is a child of the span that is current when the request is sent: the `data` or `action`
/// span of the operation that sent it (`FespalierOtel` makes it the current one while `data()` or
/// the action runs, after an `await` too), through the SDK's own context, so it is the same trace
/// and never a second SDK. It carries `fespalier.operation` `http`, `http.request.method`,
/// `server.address`, `server.port`, `url.scheme`, `url.path`, `http.response.status_code` and, for
/// an error, `error.type` (the status code of a `4xx` or `5xx` answer, the `TransportFailure`
/// class when no answer came) and an error status. A re-send of the same request (an auth replay,
/// a retry) is a span of its own with `http.request.resend_count`.
///
/// **Never recorded**: the query and the fragment (query values are app data, as with
/// `FespalierOtel(recordLocations:)`), a header value, a body, an error's text. There is no
/// `url.full`.
///
/// W3C `traceparent` and `tracestate` are added to a request only when its origin (scheme, host
/// and port) is one of [propagateTo]; the default is none, because a header is a cross-origin
/// request on the web and tells a third party your trace id. The request goes to [inner] with the
/// same `attributes` it came with (the auth replay mark, the `TransportMemo`).
///
/// The span ends when the response headers arrive: a body that breaks later is the caller's to
/// see, not part of the span. It starts no timer and listens to nothing. Nothing is made until
/// [isReady] says the SDK is up, and a failing SDK costs the span, never the request.
final class OtelTransport implements HttpTransport {
  /// A decorator over [inner]. [isReady] says whether the SDK is up: pass
  /// `() => observability.isReady` with `otel_zone`; leave it out when the app initialises the SDK
  /// itself before the first request. [propagateTo] lists the origins that get the trace headers
  /// (only the scheme, host and port of each are read).
  OtelTransport(
    this.inner, {
    bool Function()? isReady,
    Iterable<Uri> propagateTo = const <Uri>[],
  }) : _isReady = isReady,
       propagateTo = List<Uri>.unmodifiable(propagateTo);

  /// What the request is sent through.
  final HttpTransport inner;

  /// The origins that get `traceparent` and `tracestate`.
  final List<Uri> propagateTo;

  final bool Function()? _isReady;
  Tracer? _tracer;

  static const String _sendsKey = 'fespalier.otel.sends';

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
      // The SDK never started: try again at the next request.
      return null;
    }
  }

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    Span? span;
    var outgoing = request;
    try {
      final tracer = _resolve();
      if (tracer != null) {
        final started = tracer.startSpan(
          request.method.toUpperCase(),
          context: Context.current,
          kind: SpanKind.client,
          attributes: OTel.attributesFromMap(_attributes(request)),
        );
        span = started;
        if (_propagates(request.uri)) {
          final carrier = _Carrier();
          W3CTraceContextPropagator().inject(
            Context.current.withSpan(started),
            carrier.values,
            carrier,
          );
          if (carrier.values.isNotEmpty) {
            outgoing = request.copyWith(
              headers: <String, String>{...request.headers, ...carrier.values},
            );
          }
        }
      }
    } catch (_) {
      // A failing SDK costs the span, never the request.
    }

    final TransportResponse response;
    try {
      response = await inner.send(outgoing);
    } on Object catch (error) {
      _finish(span, error: error);
      rethrow;
    }
    _finish(span, status: response.statusCode);
    return response;
  }

  Map<String, Object> _attributes(TransportRequest request) {
    final uri = request.uri;
    final resend = _resendCount(request);
    return <String, Object>{
      FespalierConventions.operation: FespalierConventions.opHttp,
      FespalierConventions.httpMethod: request.method.toUpperCase(),
      if (uri.host.isNotEmpty) FespalierConventions.serverAddress: uri.host,
      FespalierConventions.serverPort: ?_portOf(uri),
      if (uri.scheme.isNotEmpty) FespalierConventions.urlScheme: uri.scheme,
      FespalierConventions.urlPath: uri.path.isEmpty ? '/' : uri.path,
      if (resend > 0) FespalierConventions.httpResendCount: resend,
    };
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

  static int? _portOf(Uri uri) {
    if (uri.hasPort) return uri.port;
    return switch (uri.scheme) {
      'https' => 443,
      'http' => 80,
      _ => null,
    };
  }

  bool _propagates(Uri uri) {
    for (final origin in propagateTo) {
      if (origin.scheme == uri.scheme &&
          origin.host == uri.host &&
          _portOf(origin) == _portOf(uri)) {
        return true;
      }
    }
    return false;
  }

  void _finish(Span? span, {int? status, Object? error}) {
    if (span == null) return;
    try {
      if (status != null) {
        span.setIntAttribute(FespalierConventions.httpStatusCode, status);
        if (status >= 400) {
          span.setStringAttribute<String>(
            FespalierConventions.errorType,
            '$status',
          );
          span.setStatus(SpanStatusCode.Error);
        }
      } else if (error != null) {
        // The class alone: the text of a failure names the host.
        span.setStringAttribute<String>(
          FespalierConventions.errorType,
          error.runtimeType.toString(),
        );
        span.setStatus(SpanStatusCode.Error);
      }
    } catch (_) {
      // A failing SDK costs this span's detail, never the request.
    } finally {
      try {
        span.end();
      } catch (_) {
        // Same.
      }
    }
  }
}

final class _Sends {
  int _count = 0;

  /// How many sends came before this one; counts it.
  int next() => _count++;
}

/// The carrier the propagator writes `traceparent` and `tracestate` into.
final class _Carrier implements TextMapSetter<String> {
  final Map<String, String> values = <String, String>{};

  @override
  void set(String key, String value) => values[key] = value;
}
