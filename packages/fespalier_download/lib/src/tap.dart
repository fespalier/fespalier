import 'package:fespalier/fespalier.dart' show TypedLocation;

import 'ports.dart';
import 'request.dart';
import 'status.dart';

/// A tap on a download's notification, as the engine hands it to the app (since 0.15.0).
///
/// It is data for the mapping to a route (`FespalierDownload.configure(route:)`): the download
/// [id], what was tapped, where the download stood when the tap arrived, and the [request] the
/// engine has for that id. The [request] is null for an id the engine does not know (a download
/// removed since, or one of another account); map such a tap to nothing.
final class DownloadTap {
  /// A tap on the notification of the download [id].
  const DownloadTap(this.id, this.kind, this.status, this.request);

  /// The download's id, the one the app gave its `DownloadRequest`.
  final String id;

  /// What was tapped.
  final DownloadTapKind kind;

  /// The status the engine had for [id] when the tap arrived. On a cold start it is the status
  /// of the registry as `open` is still settling it, so do not branch on a transient state.
  final DownloadStatus status;

  /// The request the engine holds for [id], or null.
  final DownloadRequest? request;

  /// Prints no field: the request holds a URL and headers.
  @override
  String toString() => 'DownloadTap';
}

/// How a tap opens its target (since 0.15.0).
enum DownloadOpen {
  /// `router.go`: the target replaces the stack, as a link does.
  go,

  /// `router.push`: the target goes on top of the current page. A cold start is always the
  /// initial location, whatever this says.
  push,
}

/// Where a tap goes (since 0.15.0).
final class DownloadTarget {
  /// A tap that opens [location] (with the mount prefix), with go_router's [extra].
  DownloadTarget(this.location, {this.extra, this.open = DownloadOpen.go});

  /// A tap that opens a typed route: `DownloadTarget.to(ManualRoute(id: 42))`.
  DownloadTarget.to(
    TypedLocation route, {
    Object? extra,
    DownloadOpen open = DownloadOpen.go,
  }) : this(route.location, extra: extra, open: open);

  /// The location, with the mount prefix.
  final String location;

  /// go_router's `extra`.
  final Object? extra;

  /// `go` or `push`; a cold start ignores it.
  final DownloadOpen open;
}

/// The app's mapping from a tap to a place (since 0.15.0). Null: the tap opens the app and
/// navigates nowhere. Throwing is reported and counts as null. It must be quick and synchronous.
typedef DownloadRoute = DownloadTarget? Function(DownloadTap tap);

/// Called with each notification tap the engine hears (since 0.15.0).
typedef DownloadTapObserver = void Function(DownloadTap tap);
