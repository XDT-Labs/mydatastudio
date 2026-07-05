import 'package:mydatastudio/app_logger.dart';
import 'package:flutter/material.dart';

class StatusMessage extends StatelessWidget {
  const StatusMessage({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<String>(
      stream: AppLogger.statusSubject,
      builder: (BuildContext context, AsyncSnapshot<String> msg) {
        print('[StatusMessage] ${msg.data}');
        final text = msg.data ?? '';
        return Text(
          text.toUpperCase(),
          key: UniqueKey(),
          style: const TextStyle(overflow: TextOverflow.ellipsis),
        );
      },
    );
  }
}
