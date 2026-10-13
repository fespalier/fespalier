import 'package:fespalier_download/fespalier_download.dart';

/// One download a person (or a tester) can start with a button.
///
/// The URLs and digests come from `--dart-define`, so a tester points the app at their own
/// file without writing code:
///
/// ```sh
/// flutter run \
///   --dart-define=LARGE_URL=https://example.com/big.iso \
///   --dart-define=LARGE_SHA256=<64 hex digits> \
///   --dart-define=LARGE_BYTES=<size in bytes>
/// ```
final class DemoCase {
  /// A case.
  const DemoCase({
    required this.id,
    required this.title,
    required this.help,
    required this.url,
    required this.sha256,
    required this.bytes,
    required this.path,
  });

  /// The download's id (the route `/downloads/<id>` shows it).
  final String id;

  /// The card's title.
  final String title;

  /// What to try with it.
  final String help;

  /// Where it comes from.
  final String url;

  /// The digest the file must have, as 64 hex digits.
  final String sha256;

  /// The size the file must have, or 0 to not say.
  final int bytes;

  /// The path of the file under the support folder.
  final String path;

  /// Where the file goes.
  DownloadLocation get location => DownloadLocation(DownloadBase.support, path);

  /// The request the Start button hands to the engine.
  DownloadRequest get request => DownloadRequest(
    id: id,
    url: Uri.parse(url),
    file: location,
    bytes: bytes > 0 ? bytes : null,
    sha256: sha256,
    displayName: title,
  );
}

// Public files of Alpine Linux 3.22.0 (old releases stay on the mirror), with the checksums its
// release notes publish (dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/*.sha256), on a
// server that answers `Range`.
const _alpine = 'https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64';

/// The large file: 268 MB, enough to pause, kill and cut the network in the middle of.
const largeCase = DemoCase(
  id: 'large',
  title: 'Large file (SHA-256 checked)',
  help:
      'Start it, then pause and resume it, switch on airplane mode, or kill the app while it runs.',
  url: String.fromEnvironment(
    'LARGE_URL',
    defaultValue: '$_alpine/alpine-standard-3.22.0-x86_64.iso',
  ),
  sha256: String.fromEnvironment(
    'LARGE_SHA256',
    defaultValue:
        '08283b76f95c0828f51c03ade5690eb4a4bda8e1c86f57567ae8cedaf4f04aae',
  ),
  bytes: int.fromEnvironment('LARGE_BYTES', defaultValue: 281018368),
  path: 'downloads/large.bin',
);

/// A small file (3.7 MB): finishes in seconds, for the cases that do not need a long download.
const smallCase = DemoCase(
  id: 'small',
  title: 'Small file (SHA-256 checked)',
  help:
      'A quick download: it should end Complete with the right size and digest.',
  url: String.fromEnvironment(
    'SMALL_URL',
    defaultValue: '$_alpine/alpine-minirootfs-3.22.0-x86_64.tar.gz',
  ),
  sha256: String.fromEnvironment(
    'SMALL_SHA256',
    defaultValue:
        '18879884e35b0718f017a50ff85b5e6568279e97233fc42822229585feb2fa4d',
  ),
  bytes: int.fromEnvironment('SMALL_BYTES', defaultValue: 3655173),
  path: 'downloads/small.bin',
);

/// The small file with a digest that cannot match: it must end Failed (hash mismatch) and leave
/// no file at the destination.
const wrongCase = DemoCase(
  id: 'wrong-checksum',
  title: 'Wrong checksum',
  help:
      'The small file, asked with a SHA-256 of zeros: it must fail and leave no file.',
  url: String.fromEnvironment(
    'SMALL_URL',
    defaultValue: '$_alpine/alpine-minirootfs-3.22.0-x86_64.tar.gz',
  ),
  sha256: '0000000000000000000000000000000000000000000000000000000000000000',
  bytes: 0,
  path: 'downloads/wrong-checksum.bin',
);

/// The cases of the home page, in order.
const demoCases = <DemoCase>[largeCase, smallCase, wrongCase];

/// The case for the download [id], or null.
DemoCase? caseOf(String id) {
  for (final c in demoCases) {
    if (c.id == id) return c;
  }
  return null;
}
