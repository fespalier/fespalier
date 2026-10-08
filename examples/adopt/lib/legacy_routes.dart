import 'package:adopt/screens.dart';
import 'package:fespalier/fespalier.dart';

/// The hand-written routes nobody has moved. The "before" router and the half-moved one both
/// spread this list, so a legacy page is the same code in both.
List<RouteBase> legacyRoutes() => [
  GoRoute(path: '/', builder: (context, state) => const LegacyHome()),
  GoRoute(
    path: '/legacy/orders/:id',
    builder: (context, state) =>
        LegacyOrderView(id: state.pathParameters['id']!),
  ),
];
