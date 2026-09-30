/// What the profile page hands to the edit page as an `extra`: an object that
/// isn't in the URL. `toJson` and `fromJson` are how `extra_codec.dart` saves it
/// for state restoration (and, on the web, for the browser's history).
class ProfileDraft {
  const ProfileDraft({required this.name});

  factory ProfileDraft.fromJson(Map<String, dynamic> json) =>
      ProfileDraft(name: json['name'] as String);

  final String name;

  Map<String, dynamic> toJson() => {'name': name};
}
