/// A Rust core's change stream for fespalier (since 0.13.0): [initRustCore] runs the core's `init`
/// from `startup()`, and [ChangeCodec] (since 0.18.0) decodes a core that sends raw messages (JSON,
/// bytes, a batch per message) on the way into a feed, reporting a skip as `fespalier.frb.decode`.
///
/// The feed itself is fespalier_stream's since 0.25.0, re-exported here as the same declarations:
/// [ChangeFeed] holds the one subscription in a provider, a [ChangeTopic] is a provider that
/// changes only when a matching event arrives (so watching it is the invalidation),
/// [InvalidationTable] is the pure form for an app that owns its subscription, and [ChangeBudget]
/// (since 0.21.0) holds each key of a topic to one move per tick of a provider the app fires.
/// There is no flutter_rust_bridge dependency here: the generated bindings pin their own runtime.
library;

export 'package:fespalier_stream/fespalier_stream.dart'
    show
        Change,
        ChangeBudget,
        ChangeFeed,
        ChangeTopic,
        InvalidationRule,
        InvalidationTable,
        UnknownChange,
        changeLogCapacity;
export 'src/codec.dart' show ChangeCodec;
export 'src/telemetry.dart'
    show
        frbDecodeOp,
        frbInitOp,
        frbResultAttribute,
        frbSkippedAttribute,
        initRustCore;
