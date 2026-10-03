import 'package:fespalier/fespalier.dart';
import 'package:telemetry/analytics.dart';
import 'package:telemetry/app.g.dart';

/// Every page of the app: the screen view, once the page is the one on screen. `route` is the
/// typed route of the page, so the manifest gives its pattern.
void onEnter(Ref ref, {required TypedLocation route}) => ref
    .read(views.notifier)
    .add('enter ${AppManifest.byType[route.runtimeType]?.path}');

/// The page is gone.
void onLeave(Ref ref, {required TypedLocation route}) => ref
    .read(views.notifier)
    .add('leave ${AppManifest.byType[route.runtimeType]?.path}');
