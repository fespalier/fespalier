import 'package:fespalier/fespalier.dart';

import 'flag.dart';
import 'providers.dart';

/// A guard.dart's answer for a route behind [gate] (since 0.9.0): null (go on) while the flag is on, or off with
/// [whenOff], and [orElse] otherwise.
///
/// `GuardResult guard(Ref ref) => flagGuard(ref, checkoutV2, orElse: const CartRoute().location);`
///
/// With [follow] (the default) the guard watches the flag: when it changes, the guard runs again, the router leaves
/// the route (or lets it in) and a menu entry under it hides or shows in the next frame, with no navigation. With
/// `follow: false` it reads the flag once per navigation: a page already open stays until the next one, and a menu
/// does not follow. It returns synchronously, so it composes with `??`:
/// `flagGuard(ref, labs, orElse: '/') ?? (ref.watch(session) ? null : '/login')`.
String? flagGuard(
  Ref ref,
  BoolFlag gate, {
  required String orElse,
  bool whenOff = false,
  bool follow = true,
}) {
  final on = follow ? ref.watch(flag(gate)) : ref.read(flag(gate));
  return on != whenOff ? null : orElse;
}
