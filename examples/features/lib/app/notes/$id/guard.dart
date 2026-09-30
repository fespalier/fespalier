import 'package:features/app.g.dart';
import 'package:features/models/note.dart';
import 'package:fespalier/fespalier.dart';

/// A guard can read the `extra` as well (a nullable type, like a page's): a
/// note passed as a draft isn't shown yet, so it goes home.
GuardResult guard(ProviderContainer c, {Note? extra}) =>
    extra?.title == 'draft' ? const HomeRoute().location : null;
