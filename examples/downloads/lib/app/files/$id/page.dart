import 'package:downloads/cases.dart';
import 'package:downloads/setup.dart';
import 'package:downloads/widgets.dart';
import 'package:fespalier/fespalier.dart';
import 'package:fespalier_download/fespalier_download.dart';
import 'package:flutter/material.dart';

/// What is on disk for a download: the finished file and the `.part` the transfer keeps.
typedef Disk = ({int? file, int? part});

/// Asks the files, again whenever the kind of status changes (not on every progress tick), and
/// when the page's Refresh is pressed (it invalidates this).
final diskOf = FutureProvider.autoDispose.family<Disk, String>((ref, id) async {
  ref.watch(downloadStatus(id).select((s) => s.runtimeType));
  final demo = caseOf(id);
  if (demo == null) return (file: null, part: null);
  final location = demo.location;
  final files = demoFiles;
  return (
    file: await files.length(location),
    part: await files.length(
      DownloadLocation(location.base, '${location.path}.part'),
    ),
  );
});

/// One download in detail: where it stands, what it must be, what is on disk, and the path of
/// the finished file. This is where a tap on the download's notification lands.
class FilePage extends ConsumerWidget {
  const FilePage({super.key, required this.id});

  /// The download's id.
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(downloads);
    final status = ref.watch(downloadStatus(id));
    final demo = caseOf(id);
    final disk = ref.watch(diskOf(id)).value;
    final grants = grantLog.where((g) => g.id == id).toList();
    String bytes(int? n) => n == null ? 'none' : '$n bytes (${formatBytes(n)})';
    final lines = <String>[
      'Status: ${describe(status)}',
      if (demo != null) ...[
        'Expected size: ${demo.bytes > 0 ? bytes(demo.bytes) : 'not asked'}',
        'Expected SHA-256: ${demo.sha256}',
        'Destination: support/${demo.path}',
      ],
      if (disk != null) ...[
        'File at the destination: ${bytes(disk.file)}',
        'Partial file (.part): ${bytes(disk.part)}',
      ],
      'Grants asked: ${grants.length}'
          '${grants.any((g) => g.renewal) ? ' (one after a 401 or 403)' : ''}',
    ];
    return Scaffold(
      appBar: AppBar(title: Text(demo?.title ?? id)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SelectableText(lines.join('\n'), key: const ValueKey('report')),
          const SizedBox(height: 16),
          DownloadButtons(id: id, demo: demo),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('refresh'),
              onPressed: () => ref.invalidate(diskOf(id)),
              child: const Text('Refresh the files'),
            ),
          ),
          if (status is Complete) _Path(id: id),
        ],
      ),
    );
  }
}

class _Path extends ConsumerWidget {
  const _Path({required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) => FutureBuilder<String?>(
    future: ref.read(downloadsEngine).pathOf(id),
    builder: (context, snapshot) => SelectableText(
      'On this device: ${snapshot.data ?? '...'}',
      key: const ValueKey('path'),
    ),
  );
}
