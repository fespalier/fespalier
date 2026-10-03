/// Runs the `fsp` generator from `dart run fespalier <command>`.
///
/// The `fsp` binary for this package's version is looked up in this order:
///
///  1. `FSP_BINARY`, a path you give.
///  2. The cache (`<cache>/fespalier/<version>-<target>/`).
///  3. An `fsp` on PATH whose `--version` is this package's version.
///  4. A download from the GitHub release, verified and cached. The archive's
///     SHA-256 must equal the one pinned in this package
///     (`release_checksums.dart`, written by the release workflow); a mismatch is
///     a hard failure. A package with no pins for its version (a development
///     build from a branch) falls back to the release's `.sha256` file, with a
///     warning, which only catches corruption.
///
/// A cached binary never touches the network, so a warm cache works offline.
///
/// The version is read from this package's own `pubspec.yaml`, so the package
/// and the binary it runs can't drift apart.
///
/// This file uses `dart:io` and `dart:ffi` (for the CPU architecture) only,
/// and nothing from Flutter, so `bin/fespalier.dart` starts fast. Archives are
/// unpacked with the system `tar` (macOS, Linux and Windows 10+ all ship one),
/// which saves consumers a dependency on `package:archive`. SHA-256 is
/// implemented here for the same reason.
library;

import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'release_checksums.dart' as pinned;

/// Where releases are downloaded from unless `FSP_BASE_URL` says otherwise.
const defaultBaseUrl =
    'https://github.com/fespalier/fespalier/releases/download';

/// A problem the user can act on; printed without a stack trace.
class LauncherException implements Exception {
  /// Creates an exception that prints [message].
  LauncherException(this.message);

  /// What to tell the user.
  final String message;
  @override
  String toString() => message;
}

// --- Pure helpers (unit tested) -----------------------------------------------

/// The release target for a Dart ABI (`Abi.current().toString()`, e.g.
/// `linux_x64`), or `null` when no binary is published for it.
String? fspTarget(String abi) => switch (abi) {
  'linux_x64' => 'x86_64-unknown-linux-gnu',
  'linux_arm64' => 'aarch64-unknown-linux-gnu',
  'macos_x64' => 'x86_64-apple-darwin',
  'macos_arm64' => 'aarch64-apple-darwin',
  // Windows on ARM runs the x64 build under emulation.
  'windows_x64' || 'windows_arm64' => 'x86_64-pc-windows-msvc',
  _ => null,
};

/// Whether [target] (a release target from [fspTarget]) is a Windows build.
bool isWindowsTarget(String target) => target.contains('windows');

/// `fsp-<target>.tar.gz`, or `.zip` for Windows.
String archiveName(String target) =>
    'fsp-$target.${isWindowsTarget(target) ? 'zip' : 'tar.gz'}';

/// `fsp` or `fsp.exe`.
String binaryName(String target) => isWindowsTarget(target) ? 'fsp.exe' : 'fsp';

/// `<base>/v<version>/<file>`.
Uri releaseUrl(String base, String version, String file) {
  final trimmed = base.endsWith('/')
      ? base.substring(0, base.length - 1)
      : base;
  return Uri.parse('$trimmed/v$version/$file');
}

/// The `version:` of a pubspec.yaml, or `null`.
String? parsePubspecVersion(String yaml) {
  final m = RegExp(
    r'^version:\s*["\x27]?([^\s"\x27#]+)',
    multiLine: true,
  ).firstMatch(yaml);
  return m?.group(1);
}

/// `0.1.1` from `fsp 0.1.1`, or `null`.
String? parseFspVersion(String output) {
  final m = RegExp(r'^fsp\s+(\S+)\s*$').firstMatch(output.trim());
  return m?.group(1);
}

/// The hash in a `.sha256` file (`<hex>  <name>`); `null` when it isn't one.
String? parseChecksum(String file) {
  final first = file.trim().split(RegExp(r'\s+')).first.toLowerCase();
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(first) ? first : null;
}

/// Where downloaded binaries live: `FSP_CACHE_DIR`, else the platform's user
/// cache directory (`$XDG_CACHE_HOME` or `~/.cache`, `~/Library/Caches`,
/// `%LOCALAPPDATA%`), plus `fespalier`.
String cacheRoot(Map<String, String> env, {required String os}) {
  final explicit = env['FSP_CACHE_DIR'];
  if (explicit != null && explicit.isNotEmpty) return explicit;
  final sep = os == 'windows' ? r'\' : '/';
  String? home() => env['HOME'] ?? env['USERPROFILE'];
  String base;
  switch (os) {
    case 'windows':
      final local = env['LOCALAPPDATA'];
      final h = home();
      if (local != null && local.isNotEmpty) {
        base = local;
      } else if (h != null) {
        base = '$h${sep}AppData${sep}Local';
      } else {
        throw LauncherException(
          'cannot find a cache directory; set FSP_CACHE_DIR',
        );
      }
    case 'macos':
      final h = home();
      if (h == null) {
        throw LauncherException(
          'cannot find a cache directory; set FSP_CACHE_DIR',
        );
      }
      base = '$h/Library/Caches';
    default:
      final xdg = env['XDG_CACHE_HOME'];
      final h = home();
      if (xdg != null && xdg.isNotEmpty) {
        base = xdg;
      } else if (h != null) {
        base = '$h/.cache';
      } else {
        throw LauncherException(
          'cannot find a cache directory; set FSP_CACHE_DIR',
        );
      }
  }
  return '$base${sep}fespalier';
}

// --- SHA-256 -------------------------------------------------------------------

const _k = <int>[
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5, //
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
];

/// The SHA-256 of [data] as lower-case hex.
String sha256Hex(List<int> data) {
  const mask = 0xffffffff;
  int rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & mask;

  final h = <int>[
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19, //
  ];
  // Pad: 0x80, zeros to 56 mod 64, then the bit length as 64-bit big endian.
  final padded = (data.length + 9 + 63) ~/ 64 * 64;
  final block = Uint8List(padded)
    ..setRange(0, data.length, data)
    ..[data.length] = 0x80;
  final view = ByteData.view(block.buffer);
  final bits = data.length * 8;
  view.setUint32(padded - 8, bits ~/ 0x100000000);
  view.setUint32(padded - 4, bits & mask);

  final w = List<int>.filled(64, 0);
  for (var off = 0; off < padded; off += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = view.getUint32(off + i * 4);
    }
    for (var i = 16; i < 64; i++) {
      final s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & mask;
    }
    var [a, b, c, d, e, f, g, hh] = h;
    for (var i = 0; i < 64; i++) {
      final s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      final ch = (e & f) ^ ((~e & mask) & g);
      final t1 = (hh + s1 + ch + _k[i] + w[i]) & mask;
      final s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & mask;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & mask;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & mask;
    }
    final s = [a, b, c, d, e, f, g, hh];
    for (var i = 0; i < 8; i++) {
      h[i] = (h[i] + s[i]) & mask;
    }
  }
  return h.map((x) => x.toRadixString(16).padLeft(8, '0')).join();
}

// --- The launcher --------------------------------------------------------------

/// Fetches a URL's bytes. Throws an [IOException] when the network is unreachable
/// (the launcher says so in one line) or a [LauncherException] for anything else.
typedef Fetch = Future<List<int>> Function(Uri url);

/// Finds (or downloads) the `fsp` for [version] and runs it.
class Launcher {
  /// Creates a launcher; every argument after [os] defaults to the real thing.
  Launcher({
    required this.version,
    required this.target,
    required this.env,
    required this.os,
    Fetch? fetch,
    void Function(String message)? log,
    Future<String?> Function(String executable)? probe,
    Future<void> Function(File archive, Directory into)? extract,
    String? pinnedVersion,
    Map<String, String>? pins,
  }) : pinnedVersion = pinnedVersion ?? pinned.pinnedVersion,
       pins = pins ?? pinned.pinnedChecksums,
       fetch = fetch ?? httpFetch,
       log = log ?? ((m) => stderr.writeln(m)),
       probe = probe ?? probeFspVersion,
       extract = extract ?? extractArchive;

  /// The package's version, `0.1.1`; the release tag is `v0.1.1`.
  final String version;

  /// The release target, `x86_64-unknown-linux-gnu`.
  final String target;

  /// The process environment (`FSP_BINARY`, `FSP_DART`, `PATH`, ...).
  final Map<String, String> env;

  /// `Platform.operatingSystem`.
  final String os;

  /// Downloads a URL.
  final Fetch fetch;

  /// Reports progress (stderr by default).
  final void Function(String message) log;

  /// What `<executable> --version` printed, or `null` if it couldn't run.
  final Future<String?> Function(String executable) probe;

  /// Unpacks a downloaded archive into a folder.
  final Future<void> Function(File archive, Directory into) extract;

  /// The version [pins] belong to (`''` for none), and target -> SHA-256 of its archive.
  /// Defaults to `release_checksums.dart`.
  final String pinnedVersion;

  /// Target -> SHA-256 of that target's release archive, for [pinnedVersion].
  final Map<String, String> pins;

  /// A launcher for this machine and this package.
  static Future<Launcher> forThisMachine() async {
    final target = fspTarget(Abi.current().toString());
    if (target == null) {
      throw LauncherException(
        'no fsp binary is published for ${Abi.current()}. '
        'Build it with `cargo install --git https://github.com/fespalier/fespalier fespalier` '
        'and point FSP_BINARY at it.',
      );
    }
    return Launcher(
      version: await packageVersion(),
      target: target,
      env: Platform.environment,
      os: Platform.operatingSystem,
    );
  }

  String get _baseUrl => env['FSP_BASE_URL'] ?? defaultBaseUrl;

  /// Where this version's binary is cached.
  File get cachedBinary {
    final sep = os == 'windows' ? r'\' : '/';
    return File(
      '${cacheRoot(env, os: os)}$sep$version-$target$sep${binaryName(target)}',
    );
  }

  /// The path of an `fsp` to run, downloading it if need be.
  Future<String> locate() async {
    final given = env['FSP_BINARY'];
    if (given != null && given.isNotEmpty) {
      if (!File(given).existsSync()) {
        throw LauncherException(
          'FSP_BINARY is set to $given, which does not exist',
        );
      }
      return given;
    }
    final cached = cachedBinary;
    if (cached.existsSync()) return cached.path;
    if (parseFspVersion(await probe('fsp') ?? '') == version) return 'fsp';
    await download(cached);
    return cached.path;
  }

  /// Downloads, verifies and unpacks the release archive; [to] is the binary's final path.
  Future<void> download(File to) async {
    final name = archiveName(target);
    final archiveUrl = releaseUrl(_baseUrl, version, name);
    log('fespalier: downloading fsp $version ($target) from $archiveUrl');
    final bytes = await _get(archiveUrl);

    final String expected;
    if (pinnedVersion == version) {
      // The pins ship inside the package, so a tampered release can't vouch for itself.
      final pin = pins[target];
      if (pin == null) {
        throw LauncherException(
          'this package pins checksums for fsp $version but none for $target',
        );
      }
      expected = pin;
    } else {
      log(
        'fespalier: warning: this package has no pinned checksums for fsp $version '
        "(a development build); checking the release's own .sha256 instead",
      );
      final sumFile = String.fromCharCodes(
        await _get(releaseUrl(_baseUrl, version, '$name.sha256')),
      );
      final sum = parseChecksum(sumFile);
      if (sum == null) {
        throw LauncherException(
          'the checksum file for $name is not a SHA-256 hash',
        );
      }
      expected = sum;
    }
    final actual = sha256Hex(bytes);
    if (actual != expected) {
      throw LauncherException(
        'checksum mismatch for $name: expected $expected, got $actual',
      );
    }

    final dir = to.parent..createSync(recursive: true);
    // Unpack beside the final path and rename, so a crash never leaves a half-written binary.
    final tmp = Directory('${dir.path}${os == 'windows' ? r'\' : '/'}.tmp-$pid')
      ..createSync();
    try {
      final archive = File('${tmp.path}${os == 'windows' ? r'\' : '/'}$name')
        ..writeAsBytesSync(bytes);
      await extract(archive, tmp);
      final unpacked = File(
        '${tmp.path}${os == 'windows' ? r'\' : '/'}${binaryName(target)}',
      );
      if (!unpacked.existsSync()) {
        throw LauncherException('$name did not contain ${binaryName(target)}');
      }
      if (!isWindowsTarget(target)) {
        final r = await Process.run('chmod', ['+x', unpacked.path]);
        if (r.exitCode != 0) {
          throw LauncherException(
            'could not make ${unpacked.path} executable: ${r.stderr}',
          );
        }
      }
      unpacked.renameSync(to.path);
    } finally {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    }
    log('fespalier: cached ${to.path}');
  }

  /// [fetch] with a network failure turned into the one line to show when nothing is cached.
  Future<List<int>> _get(Uri url) async {
    try {
      return await fetch(url);
    } on IOException {
      throw LauncherException(
        "fsp $version isn't cached and the download failed (offline?); "
        'run once online or set FSP_BINARY',
      );
    }
  }

  /// Runs `fsp` with [args], sharing this process's stdio; returns its exit code.
  Future<int> run(List<String> args) async {
    final path = await locate();
    final Process child;
    try {
      child = await Process.start(
        path,
        args,
        mode: ProcessStartMode.inheritStdio,
      );
    } on ProcessException catch (e) {
      throw LauncherException('could not run $path: ${e.message}');
    }
    // Ctrl-C reaches both processes through the terminal; a plain kill only reaches us.
    final term = Platform.isWindows
        ? null
        : ProcessSignal.sigterm.watch().listen((_) => child.kill());
    try {
      return await child.exitCode;
    } finally {
      await term?.cancel();
    }
  }
}

// --- Real-world implementations -------------------------------------------------

/// The `version:` of this package's own pubspec.yaml. [library] is where
/// `lib/fespalier.dart` is (default: wherever the package config says).
Future<String> packageVersion({Uri? library}) async {
  final lib =
      library ??
      await Isolate.resolvePackageUri(
        Uri.parse('package:fespalier/fespalier.dart'),
      );
  if (lib == null) {
    throw LauncherException(
      'cannot locate package:fespalier (run `flutter pub get`?)',
    );
  }
  final pubspec = File.fromUri(lib.resolve('../pubspec.yaml'));
  final version = pubspec.existsSync()
      ? parsePubspecVersion(pubspec.readAsStringSync())
      : null;
  if (version == null) {
    throw LauncherException('cannot read the version from ${pubspec.path}');
  }
  return version;
}

/// `fsp --version` of [executable], or `null` when it isn't there or fails.
Future<String?> probeFspVersion(String executable) async {
  try {
    final r = await Process.run(executable, ['--version']);
    return r.exitCode == 0 ? r.stdout.toString() : null;
  } on ProcessException {
    return null;
  }
}

/// GET through `HttpClient`, which follows redirects (GitHub serves assets from
/// another host) and honours `https_proxy`.
Future<List<int>> httpFetch(Uri url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(url);
    request.headers.set(HttpHeaders.userAgentHeader, 'fespalier-launcher');
    final response = await request.close();
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw LauncherException(
        '$url answered HTTP ${response.statusCode} (does this release exist?)',
      );
    }
    final out = BytesBuilder(copy: false);
    await response.forEach(out.add);
    return out.takeBytes();
  } finally {
    client.close();
  }
}

/// Unpacks a `.tar.gz` (or, on Windows, `.zip`) into [into] with the system `tar`.
/// Windows 10+ ships bsdtar, which reads zip files; older systems fall back to PowerShell.
Future<void> extractArchive(File archive, Directory into) async {
  final zip = archive.path.endsWith('.zip');
  var r = await _tryRun('tar', [
    zip ? '-xf' : '-xzf',
    archive.path,
    '-C',
    into.path,
  ]);
  if ((r == null || r.exitCode != 0) && zip) {
    r = await _tryRun('powershell', [
      '-NoProfile',
      '-Command',
      "Expand-Archive -Force -LiteralPath '${archive.path}' -DestinationPath '${into.path}'",
    ]);
  }
  if (r == null) {
    throw LauncherException('need `tar` on PATH to unpack ${archive.path}');
  }
  if (r.exitCode != 0) {
    throw LauncherException('could not unpack ${archive.path}: ${r.stderr}');
  }
}

Future<ProcessResult?> _tryRun(String exe, List<String> args) async {
  try {
    return await Process.run(exe, args);
  } on ProcessException {
    return null;
  }
}
