import 'package:fespalier_keypair/fespalier_keypair.dart';

/// A user-present signature was not made (since 0.21.0): the user cancelled the biometric or
/// device-credential prompt, the device has nothing to authenticate the user against, or the
/// platform destroyed the key after a change of biometrics.
///
/// It is **not** a lost session. It fails the one request (or the one renewal) that wanted the
/// prompt, and the session, the ambient key and every ordinary request go on working. A screen
/// shows "confirmation cancelled" and lets the user try again. [code] says which of the three it
/// was; [cause] is the platform's own error.
final class UserPresenceRefused implements Exception {
  /// A refused prompt: the platform's [cause].
  const UserPresenceRefused(this.cause);

  /// What the platform threw.
  final SecureSignerException cause;

  /// Why: `userAuthenticationCancelled` (the user gave up), `userAuthenticationRequired` (no
  /// biometric and no screen lock to check against) or `keyInvalidated` (the biometrics changed).
  SignerErrorCode get code => cause.code;

  /// Whether the user simply dismissed the prompt: nothing to report, the screen asks again.
  bool get cancelled => code == SignerErrorCode.userAuthenticationCancelled;

  @override
  String toString() =>
      'UserPresenceRefused: the user-present key did not sign (${code.wireName}); '
      'the session is unchanged';
}

/// Runs [sign], and turns a platform refusal of a user-present prompt into a
/// [UserPresenceRefused]. Anything else propagates unchanged.
Future<T> refusingPrompts<T>(KeyRole role, Future<T> Function() sign) async {
  try {
    return await sign();
  } on SecureSignerException catch (error) {
    if (role == KeyRole.userPresent &&
        (error.code == SignerErrorCode.userAuthenticationCancelled ||
            error.code == SignerErrorCode.userAuthenticationRequired ||
            error.code == SignerErrorCode.keyInvalidated)) {
      throw UserPresenceRefused(error);
    }
    rethrow;
  }
}
