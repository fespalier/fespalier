import 'request.dart';

/// What a decorator remembers about one LOGICAL request across all its sends (since 0.21.0): a
/// small mutable bag, carried in `TransportRequest.attributes[TransportMemo.key]`, never sent to
/// a server.
///
/// A retrier above the transport (`dio_smart_retry`, `RetryClient`) sends the same request
/// again, and a decorator sees each send as a new request. The memo is how it knows it has seen
/// this one before: `SessionTransport` keeps the user a request was authorized for, the refusal
/// that stopped it and the renewals it has spent in the memo, so a retry is refused when the
/// session it wanted is gone, and a request renews at most once however many times it is sent.
///
/// A client that sends the same logical request more than once must give every send the same
/// memo: `TransportAdapter` (`fespalier_dio`) keeps it in `RequestOptions.extra`, which is what
/// a Dio retrier reuses, and `TransportClient` (`fespalier_http`) gives each `http.BaseRequest`
/// its own. A retrier that sends a copy of the request instead of the request itself (`package:http`'s
/// `RetryClient` does) starts a new logical request with each copy, and the memo cannot follow
/// it. A request with no memo is a request seen once.
///
/// A key is any value with value equality that the decorator owns (a private `const` string is
/// enough); a decorator never reads another's. The memo holds no thread of its own and no timer.
/// `toString` prints no entry: a value can be an error that names a user.
final class TransportMemo {
  /// An empty memo.
  TransportMemo();

  /// The `TransportRequest.attributes` key that carries the memo: `fespalier.memo`.
  static const String key = 'fespalier.memo';

  final Map<Object, Object> _entries = <Object, Object>{};

  /// The value stored under [key] when it is a [T], else null.
  T? get<T extends Object>(Object key) {
    final value = _entries[key];
    return value is T ? value : null;
  }

  /// Stores [value] under [key], replacing what was there.
  void set<T extends Object>(Object key, T value) {
    _entries[key] = value;
  }

  /// Stores [value] under [key] unless [key] already holds one; returns what the memo holds
  /// under [key] after the call.
  T putIfAbsent<T extends Object>(Object key, T value) {
    final held = _entries[key];
    if (held is T) return held;
    _entries[key] = value;
    return value;
  }

  /// Forgets what is stored under [key].
  void remove(Object key) => _entries.remove(key);

  @override
  String toString() => 'TransportMemo(${_entries.length} entries)';
}

/// The memo of a [TransportRequest] (since 0.21.0).
extension TransportRequestMemo on TransportRequest {
  /// The request's [TransportMemo], or null when its client keeps none (the request is then
  /// seen once).
  TransportMemo? get memo {
    final value = attributes[TransportMemo.key];
    return value is TransportMemo ? value : null;
  }
}
