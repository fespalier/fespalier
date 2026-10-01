import 'package:features/app.g.dart';
import 'package:features/auth.dart';
import 'package:fespalier/fespalier.dart';

/// A guard in a `(group)` with no page: it guards every route in the group,
/// outermost guard first. `uri` is the location that was asked for, so the
/// login page can send people back to it.
///
/// It takes a `Ref` and watches the session, so it runs again when the session
/// changes: signing out on any page in the group moves to `/login`.
GuardResult guard(Ref ref, {required Uri uri}) =>
    ref.watch(session) ? null : LoginRoute(from: uri.toString()).location;
