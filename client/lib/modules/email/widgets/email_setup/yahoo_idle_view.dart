import 'package:flutter/material.dart';
import 'package:mydatastudio/modules/email/widgets/email_setup/step_indicator_widget.dart';
import 'package:reactive_forms/reactive_forms.dart';

class YahooIdleView extends StatelessWidget {
  const YahooIdleView({
    super.key,
    required this.form,
    required this.onConnect,
    required this.onLaunchSecurity,
  });

  final FormGroup form;
  final VoidCallback onConnect;
  final VoidCallback onLaunchSecurity;

  static const Color _yahooPurple = Color(0xFF6001D2);

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: ReactiveForm(
        formGroup: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Center(
              child: Icon(Icons.email, size: 64, color: _yahooPurple),
            ),
            const SizedBox(height: 16),
            const Center(
              child: Text(
                'Connect Yahoo Mail',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Setup Instructions',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const StepIndicatorWidget(
                    number: 1,
                    text: 'Log in to your Yahoo Account Security settings.',
                  ),
                  const StepIndicatorWidget(
                    number: 2,
                    text: 'Click "Generate app password".',
                  ),
                  const StepIndicatorWidget(
                    number: 3,
                    text:
                        'Select "Other App", name it "mydatastudio", and click Generate.',
                  ),
                  const StepIndicatorWidget(
                    number: 4,
                    text: 'Copy the 16-character code and paste it below.',
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: TextButton.icon(
                      onPressed: onLaunchSecurity,
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: const Text('Open Yahoo Security Settings'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Email Address',
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            ReactiveTextField<String>(
              formControlName: 'email',
              decoration: InputDecoration(
                hintText: 'yourname@yahoo.com',
                prefixIcon: const Icon(Icons.alternate_email),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'App Password',
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            ReactiveTextField<String>(
              formControlName: 'appPassword',
              obscureText: true,
              decoration: InputDecoration(
                hintText: 'Enter 16-character app password',
                prefixIcon: const Icon(Icons.lock_outline),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              validationMessages: {
                'required': (error) => 'App password is required',
                'minLength': (error) => 'App password should be 16 characters',
              },
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton.icon(
                onPressed: onConnect,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _yahooPurple,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                icon: const Icon(Icons.check_circle_outline),
                label: const Text(
                  'Connect Yahoo Account',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
