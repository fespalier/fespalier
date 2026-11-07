import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';

/// The wipe first, then the sign-out: what this phone saved of the account's reads goes before the
/// session ends, so the next account never sees it (`crateStackScope` is the user). Then
/// `signOut()` revokes the device on the server, signed by the user-present key where there is one
/// (it prompts), and deletes both keys. It sets `SignedOut` before its first await, so the guards
/// move the user at once.
Future<void> signOutAndWipe(WidgetRef ref) async {
  await ref.read(crateStackAccount).clear();
  await ref.read(authSession.notifier).signOut();
}

/// A session that ends without the user asking (the server revoked the device, the key is lost)
/// wipes what this phone kept for that account: its queued intents, owned rows and saved reads
/// (`crateStackAccount.clear`). By then `crateStackScope` is already null, so the account it was is
/// named (`clear(scope:)`). Sending one account's queued intent under the next account's session is
/// worse than losing it, and a revoked device's intents would only be refused again.
///
/// Installed once on the app's container, by `ready()` in `lib/app/startup.dart` (a test that makes
/// its own container calls it too).
void wipeWhenSessionEnds(ProviderContainer container) {
  container.listen<SessionState>(authSession, (previous, next) {
    if (previous is SignedIn && next is SignedOut) {
      final leaving = previous.session.user.id;
      unawaited(
        Future.sync(
          () => container.read(crateStackAccount).clear(scope: leaving),
        ),
      );
    }
  });
}
