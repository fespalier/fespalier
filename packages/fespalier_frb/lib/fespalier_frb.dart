/// A Rust core's change stream for fespalier (since 0.13.0): [ChangeFeed] holds the one
/// subscription in a provider, a [ChangeTopic] is a provider that changes only when a matching
/// event arrives (so watching it is the invalidation), [InvalidationTable] is the pure form for
/// an app that owns its subscription, and [initRustCore] runs the core's `init` from `startup()`.
/// [ChangeCodec] (since 0.18.0) decodes a core that sends raw messages (JSON, bytes, a batch per
/// message) on the way into a feed, and skips a bad or unknown one without ending it.
/// [ChangeBudget] (since 0.21.0) holds each key of a topic to one move per tick of a provider the
/// app fires, for a core that emits more events than its watchers can reload.
/// There is no flutter_rust_bridge dependency here: the generated bindings pin their own runtime.
library;

export 'src/change_feed.dart'
    show Change, ChangeBudget, ChangeFeed, ChangeTopic, changeLogCapacity;
export 'src/codec.dart' show ChangeCodec, UnknownChange;
export 'src/invalidation.dart' show InvalidationRule, InvalidationTable;
export 'src/telemetry.dart'
    show
        frbDecodeOp,
        frbInitOp,
        frbResultAttribute,
        frbSkippedAttribute,
        initRustCore;
