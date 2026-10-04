import 'dart:async';

import 'package:fespalier/fespalier.dart' show Ref;
import 'package:http/http.dart' as http;

/// Aborting a `data.dart`'s requests with its provider (since 0.9.0).
extension FespalierHttpRef on Ref {
  /// Completes when this provider is disposed or rebuilt: the `abortTrigger` of an
  /// `AbortableRequest`. Already complete after the provider is gone.
  ///
  /// Call it before the first `await`. Both dispose and rebuild discard the result of the build
  /// that asked, so a request still in flight has nobody to answer to. A request aborted this way
  /// fails with `RequestAbortedException` ("Request aborted by `abortTrigger`") after the provider
  /// is gone, so nothing reads it. It starts no timer: the future is completed inside `dispose`.
  ///
  /// ```dart
  /// final request = http.AbortableRequest('GET', url, abortTrigger: ref.abortTrigger());
  /// ```
  Future<void> abortTrigger() {
    // `onDispose` on a Ref that is gone throws: the answer is a trigger that has already fired.
    if (!mounted) return Future<void>.value();
    final trigger = Completer<void>();
    onDispose(trigger.complete);
    return trigger.future;
  }

  /// [client], with every request sent through it aborted when this provider is disposed or
  /// rebuilt. Closing the result does not close [client].
  ///
  /// Each request is sent as its `Abortable` twin with the trigger of [abortTrigger]: a `Request`
  /// as an `AbortableRequest`, a `MultipartRequest` as an `AbortableMultipartRequest`, a
  /// `StreamedRequest` as an `AbortableStreamedRequest` (its body piped). A request that already
  /// has an `abortTrigger` of its own is aborted by whichever fires first. Whether the abort
  /// reaches the network depends on the client under it: `package:http`'s own clients and
  /// `RetryClient` honour it, a `MockClient` leaves it to its handler.
  ///
  /// Call it before the first `await`:
  ///
  /// ```dart
  /// final client = ref.abortable(ref.watch(authHttpClient));
  /// ```
  http.Client abortable(http.Client client) =>
      _AbortableClient(client, abortTrigger());
}

/// A client that sends everything as an `Abortable` request with one trigger.
final class _AbortableClient extends http.BaseClient {
  _AbortableClient(this._inner, this._trigger);

  final http.Client _inner;
  final Future<void> _trigger;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(_abortableTwin(request, _trigger));

  /// The inner client belongs to whoever made it (usually a provider that closes it).
  @override
  void close() {}
}

/// [request] as the `Abortable` request of its kind, aborted when [trigger] completes (and when
/// its own trigger does, if it has one). A request of a kind this package does not know is
/// returned as it is.
http.BaseRequest _abortableTwin(
  http.BaseRequest request,
  Future<void> trigger,
) {
  // `Abortable` is a mixin of the three Abortable* classes: promote through Object.
  final Object asObject = request;
  final own = asObject is http.Abortable ? asObject.abortTrigger : null;
  final abort = own == null ? trigger : Future.any<void>([own, trigger]);
  switch (request) {
    case http.Request():
      return http.AbortableRequest(
          request.method,
          request.url,
          abortTrigger: abort,
        )
        ..headers.addAll(request.headers)
        ..bodyBytes = request.bodyBytes
        ..followRedirects = request.followRedirects
        ..maxRedirects = request.maxRedirects
        ..persistentConnection = request.persistentConnection;
    case http.MultipartRequest():
      return http.AbortableMultipartRequest(
          request.method,
          request.url,
          abortTrigger: abort,
        )
        ..headers.addAll(request.headers)
        ..fields.addAll(request.fields)
        ..files.addAll(request.files)
        ..followRedirects = request.followRedirects
        ..maxRedirects = request.maxRedirects
        ..persistentConnection = request.persistentConnection;
    case http.StreamedRequest():
      final twin =
          http.AbortableStreamedRequest(
              request.method,
              request.url,
              abortTrigger: abort,
            )
            ..headers.addAll(request.headers)
            ..contentLength = request.contentLength
            ..followRedirects = request.followRedirects
            ..maxRedirects = request.maxRedirects
            ..persistentConnection = request.persistentConnection;
      // What the caller writes to the original's sink is what the twin sends. The pipe ends with
      // the body; a body that errors fails the twin, and the error is the client's to report.
      unawaited(
        request
            .finalize()
            .pipe(twin.sink)
            .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
      return twin;
    default:
      return request;
  }
}
