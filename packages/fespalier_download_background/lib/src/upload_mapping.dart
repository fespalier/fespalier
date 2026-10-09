import 'package:background_downloader/background_downloader.dart' as bd;
import 'package:fespalier_download/fespalier_download.dart';

import 'mapping.dart';
import 'upload_request.dart';

/// The group of every upload task this package enqueues (since 0.15.0), next to the downloads'
/// `backgroundDownloadGroup`: callbacks are registered per group, so an upload's updates never
/// reach the downloads' callbacks, the app's `FileDownloader().updates` stream, or the other way
/// round.
const String backgroundUploadGroup = 'fespalier.upload';

/// The options of the upload backend by default: the plugin group of uploads, and the retries of a
/// **replay-safe** upload (an upload that is not replay safe never gets any).
const BackgroundOptions defaultUploadOptions = BackgroundOptions(
  group: backgroundUploadGroup,
);

/// The plugin task for [request] (`background_downloader` 9.6.4, since 0.15.0).
///
/// - The task id is the request id; the group is [BackgroundOptions.group]; updates are status and
///   progress.
/// - The file is the request's base and relative path, as the plugin's base folder, sub-folder
///   and file name: never an absolute path.
/// - A binary upload is `post: 'binary'` (the file is the body); a multipart one carries
///   [UploadRequest.fileField] and [UploadRequest.fields].
/// - **Retries are `0` unless the request is replay safe** ([UploadRequest.replaySafe]), then
///   [BackgroundOptions.retries]: the platform would otherwise send a POST again with nobody to
///   ask. The plugin's `UploadTask` cannot pause (`allowPause` is false for it), so there is no
///   pause cycle that could send it twice either.
/// - `userInitiated` is priority 0, `background` the plugin's default; `unmetered` is
///   `requiresWiFi`. Nothing here asks for a foreground service.
/// - The headers are the request's, then [authorization] over them; they are written to the
///   operating system's task queue in plaintext until the task ends.
///
/// The request must be valid ([UploadRequest.isValid]).
bd.UploadTask uploadTaskOf(
  UploadRequest request, {
  Map<String, String> authorization = const {},
  BackgroundOptions options = defaultUploadOptions,
  DateTime? creationTime,
}) {
  final path = request.file.path;
  final cut = path.lastIndexOf('/');
  final directory = cut < 0 ? '' : path.substring(0, cut);
  final filename = cut < 0 ? path : path.substring(cut + 1);
  final binary = request.encoding == UploadEncoding.binary;
  return bd.UploadTask(
    taskId: request.id,
    creationTime: creationTime,
    url: request.url.toString(),
    headers: {...request.headers, ...authorization},
    httpRequestMethod: request.method.name.toUpperCase(),
    post: binary ? 'binary' : null,
    fileField: request.fileField,
    fields: binary ? null : request.fields,
    filename: filename,
    directory: directory,
    baseDirectory: baseDirectoryOf(request.file.base),
    group: options.group,
    updates: bd.Updates.statusAndProgress,
    requiresWiFi: request.network == DownloadNetwork.unmetered,
    retries: request.replaySafe ? options.retries : 0,
    priority: request.priority == DownloadPriority.userInitiated
        ? userInitiatedPriority
        : backgroundPriority,
    displayName: request.displayName ?? '',
  );
}
