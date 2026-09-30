import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'failure.dart';
import 'params.dart';

/// `page.dart` — the route's screen.
///
/// `T` is what `data.dart` yields, or the route's params when there is no
/// `data.dart`. Named `Screen` because Flutter already owns `Page<T>`.
abstract class Screen<T> extends HookConsumerWidget {
  const Screen(this.data, {super.key});

  final T data;
}

/// `loading.dart` — shown while `data.dart` resolves. Inherited by subfolders,
/// so `P` must be a supertype of every descendant's params.
abstract class Loading<P extends Params> extends HookConsumerWidget {
  const Loading(this.params, {super.key});

  final P params;
}

/// `error.dart` — shown when `data.dart` throws. Inherited like [Loading].
abstract class ErrorView<P extends Params> extends HookConsumerWidget {
  const ErrorView(this.params, this.failure, {super.key});

  final P params;
  final LoadFailure failure;
}

/// `layout.dart` — wraps this folder's page and everything below it.
abstract class Layout extends HookConsumerWidget {
  const Layout(this.child, {super.key});

  final Widget child;
}

/// `not_found.dart` (root only) — unknown locations and unparsable params.
abstract class NotFoundView extends HookConsumerWidget {
  const NotFoundView(this.uri, {super.key});

  final Uri uri;
}
