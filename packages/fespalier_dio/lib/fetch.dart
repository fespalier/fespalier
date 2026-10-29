/// Dio that streams on the web (since 0.25.0): [FetchHttpClientAdapter], a Dio adapter over the
/// browser's `fetch` that hands the response body on chunk by chunk, and [webStreamingAdapter],
/// that adapter in a web build and Dio's default everywhere else.
///
/// Dio's default web adapter reads a response in one piece, so a server-sent events stream shows
/// nothing until the server ends it. Give the app's Dio this adapter when it streams:
///
/// ```dart
/// final dio = Dio()..httpClientAdapter = webStreamingAdapter();
/// final transport = DioTransport(dio); // ServerEvents(transport, url) now streams in a browser
/// ```
///
/// The fetch adapter ignores Dio's `connectTimeout` and `sendTimeout` (a timer would be needed, and
/// a stream must outlive them). Dio's `receiveTimeout` is not the adapter's: Dio applies it to the
/// body of every adapter and drops a stream that is quiet for that long, so a Dio that streams
/// leaves it null (or passes `Options(receiveTimeout: Duration.zero)` for the one request).
/// Redirects are followed by the browser, and the request body is sent in one piece. See
/// [FetchHttpClientAdapter].
///
/// This library imports neither Flutter nor fespalier, only Dio and, in a web build,
/// `package:web`.
library;

export 'src/fetch/fetch_adapter_stub.dart'
    if (dart.library.js_interop) 'src/fetch/fetch_adapter_web.dart'
    show FetchHttpClientAdapter, webStreamingAdapter;
