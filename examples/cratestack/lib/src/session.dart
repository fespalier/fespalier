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
