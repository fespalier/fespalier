import 'dart:async';

import 'package:fespalier/fespalier.dart';

/// What `(account)/nickname/` shows and edits.
class Profile {
  const Profile({required this.nickname, this.age, required this.newsletter});

  final String nickname;
  final int? age;
  final bool newsletter;
}

/// A stand-in for the profile API. `load()` hands back the same [Profile] until a save, so a
/// form can tell new data from a rebuild. The tests give it a [gate] to hold a save pending
/// without a timer, and a [failWith] to make it fail.
class ProfileServer {
  Profile _profile = const Profile(nickname: 'Ann', age: 30, newsletter: false);

  /// A save waits for this before it answers, when there is one.
  Completer<void>? gate;

  /// A save throws this after the wait, when there is one.
  Object? failWith;

  /// How many saves were asked of it, failed ones included.
  int saves = 0;

  Future<Profile> load() async => _profile;

  /// Saves, spelling the nickname its own way (trimmed, lower case): what the page shows
  /// once the data has loaded again. `admin` is taken.
  Future<Profile> save({
    required String nickname,
    required int? age,
    required bool newsletter,
  }) async {
    saves++;
    await gate?.future;
    if (failWith case final error?) throw error;
    final spelled = nickname.trim().toLowerCase();
    if (spelled == 'admin') {
      throw const FieldErrors({'nickname': 'That nickname is taken'});
    }
    return _profile =
        Profile(nickname: spelled, age: age, newsletter: newsletter);
  }
}

final profileServerProvider = Provider<ProfileServer>((ref) => ProfileServer());
