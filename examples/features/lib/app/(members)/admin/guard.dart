import 'package:features/app.g.dart';
import 'package:features/auth.dart';
import 'package:fespalier/fespalier.dart';

/// A folder's own guard runs after the ones above it: only signed-in members
/// get this far.
GuardResult guard(ProviderContainer c) =>
    c.read(isAdmin) ? null : const InboxRoute().location;
