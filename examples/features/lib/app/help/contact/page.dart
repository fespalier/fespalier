import 'package:flutter/material.dart';

/// A static sibling of `$topic`: /help/contact, /aide/contact (fr has no spelling of its own
/// here, so it keeps the canonical one) and /hilfe/kontakt all win over `/help/:topic`.
class ContactPage extends StatelessWidget {
  const ContactPage({super.key});

  @override
  Widget build(BuildContext context) => const Text('Contact us');
}
