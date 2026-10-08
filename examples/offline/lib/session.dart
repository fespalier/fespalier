import 'package:fespalier/fespalier.dart';
import 'package:fespalier_cratestack/fespalier_cratestack.dart';

/// Who is signed in on this phone, or null. It is `crateStackScope`: every intent, row and saved read
/// is keyed by it, and nothing is read or saved while it is null.
final accountId = NotifierProvider<Account, String?>(Account.new);

/// The state of [accountId]. The demo has one account, `ada`, signed in at start.
class Account extends Notifier<String?> {
  @override
  String? build() => 'ada';

  /// Signs [id] in.
  void signIn(String id) => state = id;

  /// Signs out. Use [signOutAndWipe], which empties the account's queue first.
  void signOut() => state = null;
}

/// The wipe first, then the sign-out: sending one account's queued decision under another's session is
/// worse than losing it. `clear` removes the account's intents, rows, sync cursors and saved reads.
/// (A real app wipes before `fespalier_auth`'s `signOut()`, which flips the scope before its first await.)
Future<void> signOutAndWipe(WidgetRef ref) async {
  await ref.read(crateStackAccount).clear();
  ref.read(accountId.notifier).signOut();
}
