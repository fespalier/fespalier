import 'package:features/app.g.dart';

/// Query parameters come along by name; they are optional and nullable.
String redirect({String? q}) => SearchRoute(q: q).location;
