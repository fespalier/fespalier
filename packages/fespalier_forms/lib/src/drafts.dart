import 'dart:async';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier/persist.dart' show Storage;

import 'draft_store.dart';

/// Turns a form's input into a draft that is kept per route and restored on return (since
/// 0.11.0): `NicknameRoute.useForm(ref, data: p, draft: const FormDraft())`.
///
/// A form keeps no draft unless it is given one, and never by default: a sign-in form must not
/// write a password to disk, so a field that must not be kept goes in [exclude]. Drafts are
/// written to [formDraftStorage]; without a storage nothing is kept.
final class FormDraft {
  /// Keeps the form's draft, except for the fields named in [exclude], for [maxAge].
  const FormDraft({
    this.exclude = const {},
    this.maxAge = const Duration(days: 7),
  });

  /// The names of the fields that are never written to the draft (`{'password'}`).
  final Set<String> exclude;

  /// How long a draft may be restored after it was written.
  final Duration maxAge;
}

/// Where form drafts are kept (since 0.11.0). By default the app's `dataCacheStorage`, so a form
/// that has a draft is kept in the same place as the data that has a `dataCache`; override it to
/// keep drafts apart from it (`formDraftStorage.overrideWithValue(MemoryDataStorage())`).
///
/// Null keeps nothing. A storage whose `read` is synchronous restores a draft before the first
/// build; a `Future` restores it when it completes. A storage with a size budget (as
/// `fespalier_storage`'s) may evict a draft, as it may evict anything.
final formDraftStorage = Provider<FutureOr<Storage<String, String>?>>(
  (ref) => ref.watch(dataCacheStorage),
);

/// The part of a draft's key that says whose it is (since 0.11.0): the signed-in account's id, so
/// that a draft written by one account is never restored for another. Null (the default) is one
/// draft for everybody.
final formDraftScope = Provider<String?>((ref) => null);

/// Deletes every draft there is (since 0.11.0), whatever its scope: call it when somebody signs
/// out. Completes when the storage is done.
Future<void> clearFormDrafts(WidgetRef ref) =>
    _clearAll(ref.read(formDraftStorage));

/// [clearFormDrafts] for a provider's or an action's `Ref` (since 0.11.0).
Future<void> clearFormDraftsOf(Ref ref) =>
    _clearAll(ref.read(formDraftStorage));

Future<void> _clearAll(FutureOr<Storage<String, String>?> storage) async {
  final resolved = await storage;
  if (resolved != null) await clearDrafts(resolved);
}

enum _Kind { boolean, dateTime, enumeration }

/// How the value of a field that is not text is written to a draft and read back (since 0.11.0).
/// The generated `useForm` gives one to a `bool`, a `DateTime` and an enum field; a field of
/// another type is not drafted.
final class DraftCodec<V> {
  const DraftCodec._(this._kind, this._optional, [this._values = const []]);

  /// `bool`.
  static const DraftCodec<bool> boolean = DraftCodec<bool>._(
    _Kind.boolean,
    false,
  );

  /// `bool?`.
  static const DraftCodec<bool?> optionalBoolean = DraftCodec<bool?>._(
    _Kind.boolean,
    true,
  );

  /// `DateTime`, written as ISO 8601 text.
  static const DraftCodec<DateTime> dateTime = DraftCodec<DateTime>._(
    _Kind.dateTime,
    false,
  );

  /// `DateTime?`.
  static const DraftCodec<DateTime?> optionalDateTime = DraftCodec<DateTime?>._(
    _Kind.dateTime,
    true,
  );

  /// An enum, written as the constant's name: a name that is no constant any more is dropped.
  static DraftCodec<E> enumOf<E extends Enum>(List<E> values) =>
      DraftCodec<E>._(_Kind.enumeration, false, values);

  /// A nullable enum.
  static DraftCodec<E?> optionalEnumOf<E extends Enum>(List<E> values) =>
      DraftCodec<E?>._(_Kind.enumeration, true, values);

  final _Kind _kind;
  final bool _optional;
  final List<Enum> _values;

  /// The JSON for [value].
  Object? encode(V value) {
    if (value == null) return null;
    return switch (_kind) {
      _Kind.boolean => value,
      _Kind.dateTime => (value as DateTime).toIso8601String(),
      _Kind.enumeration => (value as Enum).name,
    };
  }

  /// The value [json] stands for. Throws when it is not one.
  V decode(Object? json) {
    if (json == null) {
      if (_optional) return null as V;
      throw const FormatException('a draft value is null');
    }
    return switch (_kind) {
          _Kind.boolean => json as bool,
          _Kind.dateTime => DateTime.parse(json as String),
          _Kind.enumeration => _values.firstWhere(
            (e) => e.name == json,
            orElse: () => throw FormatException('no constant called $json'),
          ),
        }
        as V;
  }
}
