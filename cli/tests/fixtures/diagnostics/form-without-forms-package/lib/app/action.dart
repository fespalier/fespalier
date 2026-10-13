import 'package:riverpod/riverpod.dart';

typedef Note = ({String text});

Future<void> action(Ref ref, {required Note input}) async {}

Note form() => (text: '');
