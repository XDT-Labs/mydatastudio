import 'package:material_ui/material_ui.dart';

class ImapErrorView extends StatelessWidget {
  const ImapErrorView({
    super.key,
    required this.errorMessage,
    required this.onRetry,
    this.hint,
  });

  final String? errorMessage;
  final VoidCallback onRetry;

  /// Provider-specific advice for a refused login.
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error, color: Colors.red, size: 64),
        const SizedBox(height: 20),
        const Text(
          'Setup Failed',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        if (errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              errorMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              hint!,
              key: const Key('auth-failure-hint'),
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade700, height: 1.5),
            ),
          ),
        const SizedBox(height: 24),
        ElevatedButton(onPressed: onRetry, child: const Text('Try Again')),
      ],
    );
  }
}
