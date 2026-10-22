// The app's offline-first reads and writes over the real core, against the real server, as a process: the core
// seals every call with the device key, the server checks each one and seals its answer, and `ref.serve` and the
// intent queue run over `CoreTransport`.
//
//   cd examples/frb-cose/server && cargo build --locked
//   cd ../.. && FRB_COSE_SERVER_BIN=server/target/debug/frb-cose-demo-server flutter test test/e2e_test.dart
//
// Without FRB_COSE_SERVER_BIN the file skips, saying why; with FSP_REQUIRE_FRB_COSE_SERVER=1 (CI's `frb-cose` job
// and `just frb-cose`) a missing binary fails instead, so a run cannot pass by skipping. The core is the one every
// `flutter test` builds (the hook), and `initHostCore` loads it. These are plain `test`s: they use real sockets and
// a real process, which a widget test's fake async would freeze.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_keypair/fespalier_keypair.dart';
import 'package:fespalier_keypair/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frb_cose_example/app/action.dart';
import 'package:frb_cose_example/app/data.dart';
import 'package:frb_cose_example/src/config.dart';
import 'package:frb_cose_example/src/core.dart';
import 'package:frb_cose_example/src/device_key.dart';
import 'package:frb_cose_example/src/frb_core.dart';
import 'package:frb_cose_example/src/notes.dart';
import 'package:frb_cose_example/src/wiring.dart';

import 'support/host_core.dart';

/// The server's response key, as 64 hex digits. Every start gets it, so a server that restarts answers with the key
/// the core pinned.
const _scalar =
    '0707070707070707070707070707070707070707070707070707070707070707';

const _registered = CoreEvent(kind: CoreEventKind.registered, op: '');
const _forgotten = CoreEvent(kind: CoreEventKind.forgotten, op: '');
CoreEvent _called(String op) => CoreEvent(kind: CoreEventKind.called, op: op);

/// The page's read: `data.dart`, which `ref.serve`s the list over the core.
final _notes = FutureProvider<Served<List<Note>>>(
  (ref) => data(ref),
  retry: (_, _) => null,
);

/// The page's write: `action.dart`, an intent through the queue.
final _write = Provider<Future<IntentOutcome<Note>> Function(String)>(
  (ref) =>
      (text) => action(ref, input: text),
);

/// A running `frb-cose-demo-server`, from the one JSON line it prints once it listens.
final class _Server {
  _Server._(this._process, this.pin, this.port);

  final Process _process;

  /// The server as the app pins it: the hello line it printed, read the way a build's `FRB_COSE_SERVER_JWK` is.
  final ServerPin pin;

  /// The port it listens on. A restart takes the same one.
  final int port;

  static Future<_Server> start(String binary, {int port = 0}) async {
    final process = await Process.start(binary, [
      '--listen',
      '127.0.0.1:$port',
      '--server-scalar-hex',
      _scalar,
      // Stdin stays open while this test runs, so a killed test run takes the server with it.
      '--exit-when-stdin-closes',
    ]);
    unawaited(process.stderr.drain<void>());
    final lines = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .asBroadcastStream();
    unawaited(lines.drain<void>());
    try {
      final line = await lines.first.timeout(const Duration(seconds: 30));
      final hello = jsonDecode(line) as Map<String, Object?>;
      final pin = ServerPin.fromJwk(
        baseUrl: 'http://${hello['addr']}',
        audience: hello['audience']! as String,
        jwk: line,
      );
      return _Server._(process, pin, Uri.parse(pin.baseUrl).port);
    } on Object {
      process.kill();
      rethrow;
    }
  }

  Future<void> stop() async {
    _process.kill();
    await _process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }
}

/// The core's events as this test has seen them, in order: the backlog, then each new one. A call's events reach Dart
/// after the call has returned, so a test waits for the ones it expects with [until], never with a timer.
final class _Feed {
  _Feed(Stream<CoreEvent> changes) {
    _subscription = changes.listen(_on);
  }

  final List<CoreEvent> log = [];
  Completer<void> _next = Completer<void>();
  late final StreamSubscription<CoreEvent> _subscription;

  void _on(CoreEvent event) {
    log.add(event);
    final woken = _next;
    _next = Completer<void>();
    woken.complete();
  }

  /// Completes once [done] holds of the events so far. An event that never comes fails after 30 s, naming what came.
  Future<void> until(bool Function(List<CoreEvent>) done) async {
    while (!done(log)) {
      await _next.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TimeoutException(
          'the core emitted ${log.length} events, not the ones the test waits for: '
          '${log.map((e) => e.kind.name).toList()}',
        ),
      );
    }
  }

  void close() {
    _subscription.cancel().ignore();
  }
}

/// A device: the core opened with its key against a server, the app's container over that core, and the core's events.
final class _Device {
  _Device._(this.core, this.feed, this.container);

  final NotesCore core;
  final _Feed feed;
  final ProviderContainer container;

  /// Opens the core with [signer] as the device key, as `startup()` does: the device's point from the key, the
  /// server's from [pin]. Nothing is sent until the first call.
  static Future<_Device> open(ServerPin pin, KeypairSigner signer) async {
    final jwk = await signer.publicJwk();
    final x = p256Coordinate('x', jwk['x']);
    final y = p256Coordinate('y', jwk['y']);
    final core = await openNotesCore(
      config: pin.configFor(deviceX: x, deviceY: y),
      signer: signer,
    );
    final feed = _Feed(core.changes());
    final container = ProviderContainer(
      overrides: coreOverrides(
        core: core,
        identity: identityOf(x: x, y: y),
        keyKind: DeviceKeyKind.software,
      ),
    );
    return _Device._(core, feed, container);
  }

  IntentQueue get queue => container.read(intentQueue);

  Future<IntentOutcome<Note>> write(String text) =>
      container.read(_write)(text);

  Future<Served<List<Note>>> read() => container.refresh(_notes.future);

  /// Disposes the container. The feed's cancel is not awaited: the core's stream ends at its next event (or with the
  /// core), so waiting for it would hang the test's teardown.
  void close() {
    container.dispose();
    feed.close();
  }
}

/// A signer whose key does not sign: the signature the core asks for is refused, as a locked keystore refuses it.
/// The device's point is the real key's, so the core is opened the way it is in the app.
final class _RefusingSigner implements KeypairSigner {
  _RefusingSigner(this._key);

  final KeypairSigner _key;

  @override
  KeyRole get role => _key.role;

  @override
  Future<Map<String, String>> publicJwk() => _key.publicJwk();

  @override
  Future<Uint8List> sign(Uint8List signingInput, {String? reason}) =>
      Future<Uint8List>.error(StateError('the key refuses to sign'));

  @override
  Future<bool> isHardwareBacked() => _key.isHardwareBacked();

  @override
  Future<bool> exists() => _key.exists();

  @override
  Future<void> deleteKey() => _key.deleteKey();
}

void main() {
  final binary = Platform.environment['FRB_COSE_SERVER_BIN'];
  final required = Platform.environment['FSP_REQUIRE_FRB_COSE_SERVER'] == '1';
  if (binary == null || binary.isEmpty) {
    test(
      'the app against the real server',
      () {
        if (required) {
          fail(
            'FSP_REQUIRE_FRB_COSE_SERVER=1 but FRB_COSE_SERVER_BIN is not set: build '
            'examples/frb-cose/server and point FRB_COSE_SERVER_BIN at frb-cose-demo-server',
          );
        }
      },
      skip: required
          ? null
          : 'FRB_COSE_SERVER_BIN is not set (cd examples/frb-cose/server && cargo build --locked, '
                'then FRB_COSE_SERVER_BIN=server/target/debug/frb-cose-demo-server)',
    );
    return;
  }

  setUpAll(initHostCore);

  final servers = <_Server>[];
  Future<_Server> start({int port = 0}) async {
    final server = await _Server.start(binary, port: port);
    servers.add(server);
    return server;
  }

  setUp(() {
    addTearDown(() async {
      for (final server in servers) {
        await server.stop();
      }
      servers.clear();
    });
  });

  test(
    'a write is accepted and a read is served from the network, every answer sealed and verified',
    () async {
      final server = await start();
      final device = await _Device.open(
        server.pin,
        FakeKeypairSigner(seed: 'device a'),
      );
      addTearDown(device.close);

      // The first sealed call registers the key (plain CBOR), then goes out sealed. An accepted write
      // proves the answer opened: an answer the core could not verify is no answer.
      final written = await device.write('first');
      expect(written, isA<Accepted<Note>>());
      expect(
        (written as Accepted<Note>).value,
        const Note(id: 1, text: 'first'),
      );

      final read = await device.read();
      expect(read.source, ServedFrom.network);
      expect(read.value, [const Note(id: 1, text: 'first')]);

      await device.feed.until((log) => log.length >= 3);
      expect(device.feed.log, [
        _registered,
        _called(Ops.addNote),
        _called(Ops.listNotes),
      ]);
    },
  );

  test(
    'a server that is down queues the write and the read serves the device copy; a restart is recovered under the same key',
    () async {
      final first = await start();
      final device = await _Device.open(
        first.pin,
        FakeKeypairSigner(seed: 'device a'),
      );
      addTearDown(device.close);

      expect(await device.write('first'), isA<Accepted<Note>>());
      // A read with the server up keeps its answer on the device.
      expect((await device.read()).source, ServedFrom.network);

      await first.stop();

      // No answer: the intent is kept under its key, and the page says it is queued.
      final queued = await device.write('second');
      expect(queued, isA<Queued<Note>>());
      final intent = (queued as Queued<Note>).intent;

      final offline = await device.read();
      expect(offline.source, ServedFrom.local);
      expect(offline.value, [const Note(id: 1, text: 'first')]);

      await device.feed.until((log) => log.length >= 5);
      expect(device.feed.log, [
        _registered,
        _called(Ops.addNote),
        _called(Ops.listNotes),
        _called(Ops.addNote),
        _called(Ops.listNotes),
      ]);

      // The same port and key: the core's pooled connection may be dead, so a send can fail first (the core never
      // resends a sealed request). The server then refuses the device (unsigned 401), the core forgets its
      // registration, and a later send registers again and is accepted under the same key.
      await start(port: first.port);
      var drains = 0;
      var report = const DrainReport();
      while (report.accepted == 0 && drains < 3) {
        report = await device.queue.drain();
        drains++;
      }
      expect(
        report.accepted,
        1,
        reason: 'the queued write is accepted once the server is back',
      );
      expect(await device.queue.list(), isEmpty);

      await device.feed.until(
        (log) => log.skip(5).any((e) => e.kind == CoreEventKind.registered),
      );
      expect(
        device.feed.log.skip(5).where((e) => e.kind != CoreEventKind.called),
        [_forgotten, _registered],
        reason:
            'the restarted server did not know the key: it was forgotten, then registered again',
      );

      // The server keeps its notes in memory, so the restart forgot the first one; the queued write landed once, as
      // its first note (a second copy would be a second note).
      final read = await device.read();
      expect(read.source, ServedFrom.network);
      expect(read.value, [const Note(id: 1, text: 'second')]);

      // Every attempt of the queued write sent the same key, and the first write its own.
      final keys = {
        for (final row in device.core.journal())
          if (row.op == Ops.addNote) row.idempotencyKey,
      };
      expect(keys, hasLength(2));
      expect(keys, contains(intent.idempotencyKey));
    },
  );

  test(
    'a signer that gives no signature sends nothing: the write is queued, and the journal says it was not sent',
    () async {
      final server = await start();
      final device = await _Device.open(
        server.pin,
        _RefusingSigner(FakeKeypairSigner(seed: 'device a')),
      );
      addTearDown(device.close);

      expect(await device.write('nope'), isA<Queued<Note>>());
      expect(await device.queue.list(), hasLength(1));

      // The one call that was made: the registration (plain) and then the sealed request, which the core could not
      // sign. The journal row is the sealed attempt's: not sent, and no status.
      final rows = device.core.journal();
      expect(rows, hasLength(1));
      expect(rows.single.op, Ops.addNote);
      expect(rows.single.outcome, JournalOutcome.notSigned);
      expect(rows.single.sent, isFalse);
      expect(rows.single.status, isNull);

      await device.feed.until((log) => log.length >= 2);
      expect(device.feed.log, [_registered, _called(Ops.addNote)]);
    },
  );
}
