import 'package:flutter/material.dart';

class AiChatDrawer extends StatefulWidget {
  const AiChatDrawer({super.key});

  @override
  State<AiChatDrawer> createState() => _AiChatDrawer();
}

class _AiChatDrawer extends State<AiChatDrawer> {

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox.expand(
      child: Container(
        height: double.infinity,
        color: Colors.white,
        padding: const EdgeInsets.all(8),
        child: Text("AI Chat Drawer - TODO"),
      ),
    );
  }
}
