import 'dart:async';

import 'package:fespalier/fespalier.dart';

/// A stand-in for the sign-up API of `signup/`. The tests read what was [sent], make it fail
/// with [errors] and hold it with a [gate].
class SignupServer {
  /// What each call was given, as `name <email>`.
  final List<String> sent = [];

  /// A call throws these as the action's `FieldErrors`, when there are some.
  Map<String, String>? errors;

  /// A call waits for this before it answers, when there is one.
  Completer<void>? gate;

  Future<String> signUp({
    required String name,
    required String email,
    required String? company,
  }) async {
    sent.add('$name <$email>${company == null ? '' : ' at $company'}');
    await gate?.future;
    if (errors case final e?) throw FieldErrors(e);
    return 'account-${sent.length}';
  }
}

final signupServerProvider = Provider<SignupServer>((ref) => SignupServer());
