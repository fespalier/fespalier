import 'package:fespalier/fespalier.dart';

/// A page keeps its state when only its parameters change: `/remount/location/1` to
/// `/remount/location/2` is the same page to go_router. `Remount` says when it is a new one
/// instead. This is the default for the folders below, which only `never/` and `segments/`
/// override: the nearest route.dart wins. It is read when the tree is generated, so it has
/// to be one of the three `Remount` values, written out.
const remount = Remount.onLocation;
