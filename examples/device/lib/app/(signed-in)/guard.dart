import 'package:device/app.g.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';

/// Guards everything in the group: a session (this device is enrolled), or the enrolment page with
/// where the user was going. It is synchronous (startup() restored the session), it watches only
/// the session's phase, so a renewal never runs it again, and signing out moves the user in that
/// frame.
GuardResult guard(Ref ref, {required Uri uri}) =>
    requireSignedIn(ref, uri, signIn: (from) => EnrolRoute(from: from));
