/// What happened while the app started, in order. The startup test reads it to pin the order
/// `ready()` -> the router is built -> `attach()`.
final bootLog = <String>[];
