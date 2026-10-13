/// What tests use from fespalier_riverpod (since 0.13.0).
library;

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_riverpod/fespalier_riverpod.dart';

export 'package:fespalier_riverpod/fespalier_riverpod.dart' show PageInstance;

/// A [PageInstance] for a test that has no router (since 0.13.0): `TestPageInstance(ChatRoute(id: 1))`
/// is the instance `'test'`, and two with the same [id] are the same key, as two builds of one
/// page are. Give another [id] for another instance, e.g. `/c/1` pushed a second time.
///
/// ```dart
/// final one = TestPageInstance(const ChatRoute(id: 1), id: 'a');
/// final two = TestPageInstance(const ChatRoute(id: 1), id: 'b');
/// expect(container.read(chatDraft(one)), isNot(same(container.read(chatDraft(two)))));
/// ```
final class TestPageInstance<R extends TypedLocation> extends PageInstance<R> {
  /// An instance with identity [id] for [route].
  const TestPageInstance(R route, {String id = 'test'}) : super(id, route);
}
