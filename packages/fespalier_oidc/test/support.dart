// Shared by the tests: a clock a test moves by hand, a JWT built at run time, the form of a
// request a token endpoint was sent, and a store that says what was done to it. Nothing here
// waits for real time.
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_transport/testing.dart';

/// A clock a test moves by hand: `time.run(body)` runs `body` (and everything it awaits) on it.
final class TestTime {
  /// Starts at a fixed instant.
  TestTime([DateTime? start]) : now = start ?? DateTime.utc(2026, 3, 1, 12);

  /// The instant `clock.now()` answers.
  DateTime now;

  /// The clock that reads [now].
  Clock get clock => Clock(() => now);

  /// Moves [now] on.
  void elapse(Duration by) => now = now.add(by);

  /// Runs [body] with `clock.now()` reading [now].
  T run<T>(T Function() body) => withClock(clock, body);
}

const ada = AuthUser(
  id: 'ada-id',
  roles: {'admin'},
  email: 'ada@example.com',
  name: 'Ada',
);

/// A JWT built at run time (never a committed literal: secret scanners flag them).
String jwt(Map<String, Object?> claims) {
  String part(Object json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${part({'alg': 'RS256', 'typ': 'JWT'})}.${part(claims)}.c2ln';
}

/// What a request sent through a `FakeTransport` carried, read the way a token endpoint reads it.
extension SentForm on SentRequest {
  /// The `application/x-www-form-urlencoded` body as fields.
  Map<String, String> get bodyFields => Uri.splitQueryString(text);

  /// A header by name, whatever its case.
  String? header(String name) => lowerHeaders[name.toLowerCase()];
}

/// A synchronous store that keeps a log of what was done to it.
final class SpyStore implements TokenStore {
  /// A store holding [value], logging into [log].
  SpyStore(this.log, [this.value]);

  /// `read`, `write` and `delete`, in order.
  final List<String> log;

  /// What is stored.
  String? value;

  @override
  String? read() {
    log.add('read');
    return value;
  }

  @override
  void write(String value) {
    log.add('write');
    this.value = value;
  }

  @override
  void delete() {
    log.add('delete');
    value = null;
  }
}
