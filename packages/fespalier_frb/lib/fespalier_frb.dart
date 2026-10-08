/// A Rust core's change stream for fespalier (since 0.13.0): [ChangeFeed] holds the one
/// subscription in a provider, a [ChangeTopic] is a provider that changes only when a matching
/// event arrives (so watching it is the invalidation), [InvalidationTable] is the pure form for
/// an app that owns its subscription, and [initRustCore] runs the core's `init` from `startup()`.
/// There is no flutter_rust_bridge dependency here: the generated bindings pin their own runtime.
library;

export 'src/change_feed.dart' show Change, ChangeFeed, ChangeTopic;
export 'src/invalidation.dart' show InvalidationRule, InvalidationTable;
export 'src/telemetry.dart' show frbInitOp, frbResultAttribute, initRustCore;
