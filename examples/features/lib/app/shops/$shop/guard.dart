import 'package:features/app.g.dart';
import 'package:fespalier/fespalier.dart';

/// Guards get segments too.
GuardResult guard(ProviderContainer c, {required String shop}) =>
    shop == 'closed' ? const HomeRoute().location : null;
