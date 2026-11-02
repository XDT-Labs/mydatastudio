import 'package:material_ui/material_ui.dart';

/// Shown while a mail account is being verified or connected.
class ImapLoadingView extends StatelessWidget {
  const ImapLoadingView({super.key, this.message = 'Verifying connection…'});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 20),
        Text(
          message,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}
