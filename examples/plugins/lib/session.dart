import 'package:fespalier/fespalier.dart';

/// Whether someone is signed in: what `(members)/guard.dart` checks.
final session = NotifierProvider<SessionNotifier, bool>(SessionNotifier.new);

/// The session flag.
class SessionNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  /// Signs in or out.
  void set(bool value) => state = value;
}
