import 'package:fespalier/fespalier.dart';

/// The order, as the server would say it: a `data` span while it loads.
Future<String> data(Ref ref, {required int id}) async => 'Order $id';
