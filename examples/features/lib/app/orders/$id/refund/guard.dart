import 'package:features/app.g.dart';
import 'package:fespalier/fespalier.dart';

/// Order 0 was refunded already. The guard of the refund folder runs for every route in
/// it, `confirm/` included, although `confirm/` is not a child of the refund page.
GuardResult guard(ProviderContainer c, {required int id}) =>
    id == 0 ? OrderRoute(id: id).location : null;
