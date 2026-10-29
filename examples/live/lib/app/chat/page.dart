import 'dart:convert';

import 'package:fespalier/fespalier.dart';
import 'package:fespalier_stream/fespalier_stream.dart';
import 'package:fespalier_stream/web_socket.dart';
import 'package:flutter/material.dart';
import 'package:live/chat.dart';
import 'package:live/widgets.dart';

/// A WebSocket chat (lib/chat.dart): a ticket fetched through the app's transport before every
/// connect, the room joined again on every open, and messages both ways. When the ticket endpoint
/// refuses (the server's "refuse tickets"), the chat stops trying and says you are signed out.
class ChatPage extends HookConsumerWidget {
  const ChatPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = useTextEditingController();
    final log = ref.watch(chat.latest);
    final status = ref.watch(chat.status).value;
    final error = log.error;
    if (error is DataRefusal) {
      return _SignedOut(
        reason: error is SocketTicketRefused
            ? 'The server refused a ticket (${error.statusCode}).'
            : 'The server refused the chat.',
      );
    }
    final open = status is LiveOpen || status is LivePaused && status.connected;
    void send() {
      final text = draft.text.trim();
      if (text.isEmpty) return;
      try {
        ref.read(chatSocket).send(SocketText(jsonEncode({'say': text})));
        draft.clear();
      } on StateError {
        // Closed since the button was drawn: the status says so, and the next open takes the next try.
      }
    }

    final lines = log.value?.lines ?? const <ChatLine>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StatusBanner(status),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('The chat stopped: $error'),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final line in lines)
                line.from == null
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          line.text,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text('${line.from}: ${line.text}'),
                      ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: draft,
                  enabled: open,
                  decoration: const InputDecoration(labelText: 'Message'),
                  onSubmitted: (_) => send(),
                ),
              ),
              IconButton(
                tooltip: 'Send',
                icon: const Icon(Icons.send),
                onPressed: open ? send : null,
              ),
            ],
          ),
        ),
        const ServerControls([
          ServerButton('Message from the other phone', 'chat/other'),
          ServerButton('Close the socket', 'chat/kick'),
          ServerButton('Refuse tickets', 'admin/refuse-tickets?on=true'),
          ServerButton('Accept tickets', 'admin/refuse-tickets?on=false'),
        ]),
      ],
    );
  }
}

/// The ticket endpoint said no: nothing opens the chat again until the user signs in again.
class _SignedOut extends ConsumerWidget {
  const _SignedOut({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('You are signed out of the chat'),
          const SizedBox(height: 8),
          Text(reason),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => ref.read(chatSession.notifier).signIn(),
            child: const Text('Sign in again'),
          ),
          const ServerControls([
            ServerButton('Accept tickets', 'admin/refuse-tickets?on=false'),
          ]),
        ],
      ),
    ),
  );
}
