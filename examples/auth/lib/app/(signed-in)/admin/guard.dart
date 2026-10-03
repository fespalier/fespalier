import 'package:auth/app.g.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_auth/fespalier_auth.dart';

/// Runs after the group's guard, so the user is signed in: only an admin gets in, anybody else is
/// sent to /forbidden. It watches only that answer: a refresh does not run it again.
GuardResult guard(Ref ref, {required Uri uri}) => requireRole(
  ref,
  uri,
  'admin',
  signIn: (from) => SignInRoute(from: from),
  forbidden: const ForbiddenRoute(),
);
