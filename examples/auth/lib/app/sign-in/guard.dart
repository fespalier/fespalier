import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';

/// The sign-in page's own guard, beside the guarded group. Without it signing in changes the session
/// and nothing moves; with it, the page goes back to `from` (or `/`) as soon as there is a session,
/// and the page itself has no navigation code.
GuardResult guard(Ref ref, {String? from}) =>
    redirectIfSignedIn(ref, from: from);
