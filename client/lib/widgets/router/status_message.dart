import 'package:mydatastudio/app_logger.dart';
import 'package:material_ui/material_ui.dart';

/// Module logger. AppLogger reaches the session log file; print() does not.
final AppLogger _logger = AppLogger(null);

class StatusMessage extends StatelessWidget {
  const StatusMessage({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<String>(
      stream: AppLogger.statusSubject,
      builder: (BuildContext context, AsyncSnapshot<String> msg) {
        _logger.d('[StatusMessage] ${msg.data}');
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
