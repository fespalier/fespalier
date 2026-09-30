import 'package:fespalier/fespalier.dart';

/// The route's own data (a String), next to the section's `Team`.
Future<String> data(Ref ref, {required int member}) async => 'member #$member';
