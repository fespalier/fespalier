// Shared by the tests: a clock a test moves by hand, a container on the fakes, and a store that
// says what was done to it. Nothing here waits for real time.
import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_auth/testing.dart';
import 'package:flutter_test/flutter_test.dart' show addTearDown;
import 'package:http/http.dart' as http;

/// A clock a test moves by hand: `withClock(time.clock, body)` runs `body` (and everything it
/// awaits) on it.
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
const bob = AuthUser(id: 'bob-id', name: 'Bob');

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

/// A store whose answers a test completes by hand: restore is async only with this one.
final class GatedStore implements TokenStore {
  /// A store that answers `read` when [gate] completes.
  GatedStore(this.gate, [this.value]);

  /// What `read` waits for.
  final Completer<void> gate;

  /// What is stored.
  String? value;

  @override
  Future<String?> read() async {
    await gate.future;
    return value;
  }

  @override
  Future<void> write(String value) async => this.value = value;

  @override
  Future<void> delete() async => value = null;
}

/// A container over [fakeAuth], disposed when the test ends.
ProviderContainer containerFor({
  AuthUser? signedInAs,
  FakeAuthBackend? backend,
  TokenStore? store,
  List<Uri> apiOrigins = const [],
  Duration? tokenLifetime,
  http.Client? client,
}) {
  final container = ProviderContainer(
    overrides: fakeAuth(
      client: client,
      signedInAs: signedInAs,
      backend: backend,
      store: store,
      apiOrigins: apiOrigins,
      tokenLifetime: tokenLifetime,
    ),
  );
  addTearDown(container.dispose);
  return container;
}
