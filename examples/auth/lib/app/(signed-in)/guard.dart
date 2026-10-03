import 'package:auth/app.g.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';

/// Guards everything in the group: a session, or the sign-in page with where the user was going.
/// It is synchronous (startup() read the stored session), it watches only the session's phase, so
/// a token refresh never runs it again, and signing out moves the user in that frame.
GuardResult guard(Ref ref, {required Uri uri}) =>
    requireSignedIn(ref, uri, signIn: (from) => SignInRoute(from: from));
