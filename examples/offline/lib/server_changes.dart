import 'package:fespalier/fespalier.dart';
import 'package:fespalier/startup.dart' show Override;
import 'package:fespalier_cratestack/fespalier_cratestack.dart';
import 'package:fespalier_stream/fespalier_stream.dart';
import 'package:fespalier_transport/fespalier_transport.dart';
import 'package:offline/demo/demo_server.dart';
import 'package:offline/network.dart';

/// Where the server is. The demo's subscription transport is in-process and reads only the path.
final demoBase = Uri.parse('https://shop.example/');

/// What the subscription is read through: the demo server's endpoint, behind the app bar's switch. A real
/// app passes the transport its other calls go through, so its session or signature applies.
final subscriptionTransport = Provider<HttpTransport>(
  (ref) => SwitchedHttpTransport(
    ref.watch(demoServer).subscriptions,
    () => ref.read(networkOnline),
  ),
);

/// The server's changes to notes: CrateStack's `@@subscribe` stream as a change feed (since 0.25.0). It
/// opens when `autoSync` first watches [serverPush]'s signal, waits when it drops, and opens again when
/// the network comes back. CrateStack sends no event ids, so every reopen is a gap, and a gap moves
/// `any` too: the app syncs after it, since it may have missed a change. No `idle`: CrateStack sends no
/// heartbeat, so a quiet subscription would be closed while healthy.
///
/// `connect` watches who is signed in (`crateStackScope`, which is `accountId` here): signing in as
/// someone else, or out, closes the connection and opens one under the new session. That is also how a
/// subscription the server refused (a 401 at a signed-out start ends it for good) opens after sign-in.
final serverChanges = ChangeFeed<CrateStackModelEvent>.live(
  (ref, _) {
    ref.watch(crateStackScope);
    return crateStackEvents(
      ref.watch(subscriptionTransport),
      demoBase,
      'model.Note.subscribe',
    );
  },
  rules: LiveRules(reconnectOn: [reconnectSignal]),
  name: 'serverChanges',
);

/// A sync whenever the server says a note changed: `autoSync` follows `syncPushSignal`. The event only
/// says *that* something changed; the sync reads the rows (`syncPull`), and the page shows those, never
/// the event's `data`, which CrateStack sends without applying any read policy.
Override serverPush() =>
    syncPushSignal.overrideWith((ref) => ref.watch(serverChanges.any));
