import 'package:features/nicknames.dart';
import 'package:fespalier/fespalier.dart';

/// The profile the form below starts from. `action.dart` beside it patches this value while a
/// save is in flight (`optimistic()`), and the page takes it by type.
Future<Profile> data(Ref ref) => ref.read(profileServerProvider).load();
