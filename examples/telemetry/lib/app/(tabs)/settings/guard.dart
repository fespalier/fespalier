import 'package:fespalier/fespalier.dart';
import 'package:telemetry/session.dart';

/// A `guard` span, with its decision (`pass` or `redirect`) as an attribute.
GuardResult guard(Ref ref) => ref.read(signedIn) ? null : '/login';
