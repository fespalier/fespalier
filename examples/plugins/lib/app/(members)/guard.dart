import 'package:fespalier/fespalier.dart';
import 'package:plugins/app.g.dart';
import 'package:plugins/session.dart';

/// Guards every route in the group. A notification tap goes through it like any link: signed out,
/// it lands on /login?from=..., and the login page sends the person back.
GuardResult guard(Ref ref, {required Uri uri}) =>
    ref.watch(session) ? null : LoginRoute(from: uri.toString()).location;
