/// Server-sent events for fespalier (since 0.25.0).
///
/// - The wire: [EventStreamDecoder] reads a `text/event-stream` body by the WHATWG rules into
///   [ServerEvent]s, [EventIdUpdate]s, [RetryHint]s and [Heartbeat]s, and [ServerEvents] is a [LiveConnection] to an
///   event stream over the app's `HttpTransport`, so its decorators (a session, a signature, a
///   trace) apply. `transport.serverEvents(url)` is the simple form, a plain `Stream` for a
///   `data.dart`.
/// - Riverpod: [LiveFeed] and [LiveFeedFamily] hold a connection in a provider whose value is the
///   last event and whose [LiveStatus] says where the connection is; they reconnect on the app's
///   signals ([LiveRules]) and its tick ([streamTicker]), and never start a timer, a backoff or a
///   retry of their own.
/// - Changes (in fespalier_frb from 0.13.0, here since 0.25.0, and re-exported there): [ChangeFeed]
///   holds a change stream (a Rust core's, or a server's over a live connection with
///   [ChangeFeed.live]) in one subscription, a [ChangeTopic] is a provider that moves only when an
///   event that concerns its key arrives (so watching it is the invalidation), [ChangeBudget] holds
///   a busy key to one move per tick, and [InvalidationTable] is the pure form. [EventCodec]
///   decodes raw messages on the way in, and skips a bad or unknown one without ending the stream.
/// - Telemetry: [FespalierStreamConventions], two short root spans per connection and one per
///   skipped message, constants only.
/// - WebSockets (since 0.25.0) are `package:fespalier_stream/web_socket.dart`, a library of its
///   own, so that this one imports no `package:web_socket`: a socket held by the same feeds, signed
///   in with a ticket fetched through the transport.
///
/// `package:fespalier_stream/testing.dart` has the fakes.
library;

export 'src/codec.dart' show DecodeReport, EventCodec, UnknownChange;
export 'src/errors.dart'
    show ServerEventsRefused, ServerEventsRejected, ServerEventsUnavailable;
export 'src/riverpod/invalidation.dart'
    show InvalidationRule, InvalidationTable;
export 'src/riverpod/live_feed.dart'
    show
        Change,
        ChangeBudget,
        ChangeFeed,
        ChangeTopic,
        changeLogCapacity,
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
    show EventIdUpdate, EventStreamItem, Heartbeat, RetryHint, ServerEvent;
