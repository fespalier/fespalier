/// Background downloads for fespalier (since 0.15.0): a `DownloadBackend` over
/// `background_downloader`. The operating system runs the transfer (WorkManager and user-initiated
/// data transfer jobs on Android, a background `URLSession` on iOS), so it goes on while the app is
/// in the background and after it was closed.
///
/// `BackgroundDownloaderBackend` is the backend; `mapping.dart`'s functions (a request as a plugin
/// task, a plugin update as a status) are pure and public so that an app can test its own setup
/// without the plugin. The fakes are in `package:fespalier_download_background/testing.dart`.
library;

export 'src/backend.dart';
export 'src/mapping.dart'
    show
        BackgroundOptions,
        MappedStatus,
        NotificationPlan,
        Progress,
        TaskExpectation,
        backgroundDownloadGroup,
        backgroundPriority,
        baseDirectoryOf,
        downloadStatusOf,
        downloadTaskOf,
        failureOf,
        locationOf,
        notificationPlanOf,
        pathProbeOf,
        progressOf,
        userInitiatedPriority;
export 'src/platform.dart';
export 'src/plugin_transport.dart';
export 'src/transport.dart';
