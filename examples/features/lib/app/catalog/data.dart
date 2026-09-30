import 'package:features/catalog.dart';
import 'package:fespalier/fespalier.dart';

/// No parameters: the route's data is the provider itself.
ProviderListenable<AsyncValue<List<String>>> data() => featuredProvider;
