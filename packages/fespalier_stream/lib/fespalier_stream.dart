/// Server-sent events for fespalier (since 0.25.0).
///
/// - The wire: [EventStreamDecoder] reads a `text/event-stream` body by the WHATWG rules into
///   [ServerEvent]s, [RetryHint]s and [Heartbeat]s, and [ServerEvents] is a [LiveConnection] to an
///   event stream over the app's `HttpTransport`, so its decorators (a session, a signature, a
///   trace) apply. `transport.serverEvents(url)` is the simple form, a plain `Stream` for a
///   `data.dart`.
/// - Riverpod: [LiveFeed] and [LiveFeedFamily] hold a connection in a provider whose value is the
///   last event and whose [LiveStatus] says where the connection is; they reconnect on the app's
///   signals ([LiveRules]) and its tick ([streamTicker]), and never start a timer, a backoff or a
///   retry of their own.
/// - Telemetry: [FespalierStreamConventions], two short root spans per connection, constants only.
///
/// `package:fespalier_stream/testing.dart` has the fakes.
library;

export 'src/errors.dart'
    show ServerEventsRefused, ServerEventsRejected, ServerEventsUnavailable;
export 'src/riverpod/live_feed.dart'
    show
        LiveFeed,
        LiveFeedFamily,
        LiveResumePoints,
        LiveRules,
        StreamTicker,
        liveResumePoints,
        streamTicker;
export 'src/server_events.dart' show ServerEvents, ServerEventsOnTransport;
export 'src/telemetry.dart' show FespalierStreamConventions;
export 'src/wire/event_stream_decoder.dart'
    show EventStreamDecoder, EventStreamTooLarge;
export 'src/wire/live_connection.dart'
    show LiveConnection, LiveConnectionConvert;
export 'src/wire/live_status.dart'
    show
        LiveConnecting,
        LiveDone,
        LiveDrop,
        LiveEnd,
        LiveOpen,
        LivePaused,
        LiveStatus,
        LiveWaiting;
export 'src/wire/server_event.dart'
    show EventStreamItem, Heartbeat, RetryHint, ServerEvent;
