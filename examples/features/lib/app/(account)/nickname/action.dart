import 'package:features/nicknames.dart';
import 'package:fespalier/fespalier.dart';

/// The input of the action, and so the fields of its form: a record type with named fields
/// (since 0.8.0).
typedef NicknameFields = ({String nickname, int? age, bool newsletter});

/// The form starts from the profile the page shows. The fields the user has not changed follow
/// the data when it loads again.
NicknameFields form(Profile profile) => (
      nickname: profile.nickname,
      age: profile.age,
      newsletter: profile.newsletter,
    );

/// Checked on the device before the action runs, and live in the form after a first submit.
FieldErrors? validate(NicknameFields input) => FieldErrors({
      if (input.nickname.trim().isEmpty) 'nickname': 'Enter a nickname',
      if (input.age case final age? when age < 13)
        'age': 'You must be 13 or older',
    });

/// What the page shows of its data.dart while the save is in flight; a failure takes it back,
/// and a success keeps it until the profile has loaded again.
Profile optimistic(Profile current, NicknameFields input) => Profile(
      nickname: input.nickname,
      age: input.age,
      newsletter: input.newsletter,
    );

/// The server has the last word: a taken nickname comes back as a field error.
Future<Profile> action(Ref ref, {required NicknameFields input}) =>
    ref.read(profileServerProvider).save(
          nickname: input.nickname,
          age: input.age,
          newsletter: input.newsletter,
        );
