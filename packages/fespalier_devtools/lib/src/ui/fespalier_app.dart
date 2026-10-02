/// The extension's one screen: a status line, the go-to bar and three tabs.
library;

import 'package:devtools_app_shared/ui.dart';
import 'package:flutter/material.dart';

import '../client.dart';
import '../controller.dart';
import '../protocol.dart';
import 'chips.dart';
import 'go_to_bar.dart';
import 'location_panel.dart';
import 'routes_panel.dart';
import 'stack_panel.dart';

/// What the status line says when something is not right, one text per [FespalierStatus].
String statusText(
  FespalierController controller,
) => switch (controller.status) {
  FespalierStatus.waiting => 'Waiting for the app…',
  FespalierStatus.unsupported =>
    'This app does not use fespalier 0.7.0 or later, or runs in release mode',
  FespalierStatus.mismatch =>
    'The app speaks protocol ${controller.statusDetail}; '
        'this extension speaks $devToolsProtocol',
  FespalierStatus.notMounted =>
    'fespalier is loaded, but the app has not mounted its routes yet',
  FespalierStatus.noRouter =>
    'fespalier is loaded but no router is attached: '
        'call devToolsAttach(router) if you mount() into your own GoRouter',
  FespalierStatus.failed =>
    'Could not read the app: ${controller.statusDetail}',
  FespalierStatus.ready =>
    'fespalier · protocol $devToolsProtocol · '
        '${controller.tree?.appDir ?? '?'} · router attached',
};

/// The extension, for the app [client] talks to. It owns the controller it builds, and leaves the
/// client to whoever made it.
class FespalierApp extends StatefulWidget {
  /// The extension for [client].
  const FespalierApp({super.key, required this.client});

  /// The app.
  final FespalierClient client;

  @override
  State<FespalierApp> createState() => _FespalierAppState();
}

class _FespalierAppState extends State<FespalierApp>
    with SingleTickerProviderStateMixin {
  late final FespalierController _controller = FespalierController(
    widget.client,
  );
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final status = _controller.status;
        final hasTabs =
            status == FespalierStatus.ready ||
            status == FespalierStatus.noRouter;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(controller: _controller),
            if (status == FespalierStatus.ready)
              GoToBar(controller: _controller),
            if (hasTabs) ...[
              TabBar(
                controller: _tabs,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: const [
                  Tab(text: 'Location'),
                  Tab(text: 'Stack'),
                  Tab(text: 'Routes'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    LocationPanel(controller: _controller),
                    StackPanel(controller: _controller),
                    RoutesPanel(controller: _controller),
                  ],
                ),
              ),
            ] else
              Expanded(child: _Problem(controller: _controller)),
          ],
        );
      },
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});

  final FespalierController controller;

  @override
  Widget build(BuildContext context) {
    final ready = controller.status == FespalierStatus.ready;
    final tone = switch (controller.status) {
      FespalierStatus.ready => ChipTone.accent,
      FespalierStatus.waiting => ChipTone.neutral,
      FespalierStatus.noRouter ||
      FespalierStatus.notMounted => ChipTone.warning,
      _ => ChipTone.error,
    };
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          Flexible(
            child: Align(
              alignment: Alignment.centerLeft,
              child: KindChip(statusText(controller), tone: tone),
            ),
          ),
          const SizedBox(width: denseSpacing),
          DevToolsButton(
            key: const Key('refresh'),
            icon: Icons.refresh,
            tooltip: 'Fetch the routes, the location and the history again',
            onPressed: controller.refresh,
          ),
          PopupMenuButton<String>(
            key: const Key('clear-menu'),
            tooltip: 'Clear what the app keeps',
            enabled: ready,
            icon: const Icon(Icons.delete_sweep_outlined),
            onSelected: controller.clear,
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: ClearWhat.history,
                child: Text('Clear history'),
              ),
              PopupMenuItem(value: ClearWhat.all, child: Text('Clear all')),
            ],
          ),
        ],
      ),
    );
  }
}

/// What the body says when there are no tabs to show.
class _Problem extends StatelessWidget {
  const _Problem({required this.controller});

  final FespalierController controller;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            statusText(controller),
            key: const Key('problem'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          if (controller.status == FespalierStatus.failed) ...[
            const SizedBox(height: 12),
            DevToolsButton(
              key: const Key('retry'),
              label: 'Retry',
              onPressed: controller.refresh,
            ),
          ],
        ],
      ),
    ),
  );
}
