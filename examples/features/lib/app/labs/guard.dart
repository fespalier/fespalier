import 'package:features/app.g.dart';
import 'package:features/flags.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_flags/fespalier_flags.dart';

/// /labs is there while the `labs` flag is on. The guard watches the flag, so turning it off takes the app off
/// /labs, and the menu, which asks this guard, hides the entry: nothing else knows about the flag.
GuardResult guard(Ref ref) =>
    flagGuard(ref, labs, orElse: const HomeRoute().location);
