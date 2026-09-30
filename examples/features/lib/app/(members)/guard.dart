import 'package:features/app.g.dart';
import 'package:features/auth.dart';
import 'package:fespalier/fespalier.dart';

/// A guard in a `(group)` with no page: it guards every route in the group,
/// outermost guard first. `uri` is the location that was asked for, so the
/// login page can send people back to it.
GuardResult guard(ProviderContainer c, {required Uri uri}) =>
    c.read(session) ? null : LoginRoute(from: uri.toString()).location;
