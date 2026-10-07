/// Fakes for a widget test of an app that uses fespalier_push (since 0.13.0). No plugin, no
/// channel and no timer: a test taps a notification, delivers a message or refreshes the token by
/// hand.
///
/// ```dart
/// final push = FakePushSource(initial: const PushMessage(id: '1', data: {'link': '/orders/42'}));
/// FespalierPush.configure(source: push, route: pushRoute);
/// await tester.pumpWidget(AppMain.root());
/// push.tap(const PushMessage(id: '2', data: {'link': '/orders/43'}));
/// ```
library;

import 'dart:async';

import 'package:fespalier/startup.dart' show Override;

import 'fespalier_push.dart';

/// A [PushSource] driven by hand.
class FakePushSource extends PushSource {
  /// A source whose [initialTap] answers [initial] once, whose token is [token] (when not null),
  /// and whose permission is [permissionAnswer].
  FakePushSource({
    PushMessage? initial,
    String? token,
    this.permissionAnswer = PushPermission.notDetermined,
  }) : _initial = initial,
       _token = token;

  PushMessage? _initial;
  String? _token;
  final _taps = StreamController<PushMessage>.broadcast();
  final _received = StreamController<PushMessage>.broadcast();
  final _tokens = StreamController<String>.broadcast();

  /// What [permission] answers, and what [requestPermission] answers and then keeps.
  PushPermission permissionAnswer;

  /// How many times [requestPermission] was called: the package must leave it at 0.
  int permissionRequests = 0;

  @override
  FutureOr<PushMessage?> initialTap() {
    final message = _initial;
    _initial = null;
    return message;
  }

  @override
  Stream<PushMessage> get taps => _taps.stream;

  @override
  Stream<PushMessage> get received => _received.stream;

  @override
  Stream<String> get tokens async* {
    final current = _token;
    if (current != null) yield current;
    yield* _tokens.stream;
  }

  @override
  Future<PushPermission> permission() => Future.value(permissionAnswer);

  @override
  Future<PushPermission> requestPermission() {
    permissionRequests++;
    if (permissionAnswer == PushPermission.notDetermined) {
      permissionAnswer = PushPermission.granted;
    }
    return Future.value(permissionAnswer);
  }

  /// A tap on a notification while the app runs.
  void tap(PushMessage message) => _taps.add(message);

  /// The tap stream fails (a plugin error).
  void tapError(Object error) => _taps.addError(error);

  /// The token stream fails.
  void tokenError(Object error) => _tokens.addError(error);

  /// A message delivered in the foreground.
  void deliver(PushMessage message) => _received.add(message);

  /// A new token (a refresh); it is also the current one for a later listener.
  void emitToken(String token) {
    _token = token;
    _tokens.add(token);
  }

  /// Closes the streams.
  Future<void> close() =>
      Future.wait([_taps.close(), _received.close(), _tokens.close()]);
}

/// The overrides that bind [pushSource] to [source], for `ProviderScope(overrides: ...)` or
/// `pumpRouter(overrides: ...)` in a test that does not boot the adapter.
List<Override> pushTestOverrides(PushSource source) => [
  pushSource.overrideWithValue(source),
];
