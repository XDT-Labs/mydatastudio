import 'package:mydatastudio/models/tables/app_user.dart';
import 'package:flutter/material.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:password_dart/password_dart.dart';
import 'package:uuid/uuid.dart';

class SetupStep1 extends StatelessWidget {
  SetupStep1({super.key, required this.onCancel, required this.onSubmit});

  final VoidCallback onCancel;
  final void Function(AppUser) onSubmit;

  final infoForm = FormGroup(
    {
      'name': FormControl<String>(validators: [Validators.required]),
      'password': FormControl<String>(
        validators: [Validators.required, Validators.minLength(4)],
      ),
      'confirmPassword': FormControl<String>(
        validators: [Validators.required, Validators.minLength(4)],
      ),
    },
    validators: [Validators.mustMatch('password', 'confirmPassword')],
  );

  void onStepContinueHandler(BuildContext context) {
    if (infoForm.valid) {
      //Create User
      var name = infoForm.findControl('name')?.value;
      var password = infoForm.findControl('password')?.value;
      if (password != null) {
        var algorithm = PBKDF2(
          blockLength: 64,
          iterationCount: 10000,
          desiredKeyLength: 64,
        );
        var hash = Password.hash(password, algorithm);

        //double check the hash
        if (!Password.verify(password, hash)) {
          throw Exception('Password hash failed');
        }

        //password is a must have required field
        AppUser appUser = AppUser(
          id: const Uuid().v4().toString(),
          name: name,
          email: '',
          password: hash,
          localStoragePath: '',
          // Carried in memory only so setup completion can create the credential
          // vault from it (AUDIT M2); never written to the DB.
          plaintextPassword: password,
        );

        //call callback and proceed to next step
        onSubmit(appUser);
      }
    }
  }

  InputDecoration _decoration(
    BuildContext context, {
    required String label,
    required IconData icon,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return InputDecoration(
      label: Text(label),
      prefixIcon: Icon(icon),
      filled: true,
      fillColor: colorScheme.surfaceContainerHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return ReactiveForm(
      formGroup: infoForm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Create your account',
            style: textTheme.titleLarge?.copyWith(color: colorScheme.onSurface),
          ),
          const SizedBox(height: 4),
          Text(
            'This account stays on this device and protects access to your archive.',
            style: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          ReactiveTextField(
            formControlName: 'name',
            decoration: _decoration(
              context,
              label: 'Name',
              icon: Icons.person_outline,
            ),
          ),
          const SizedBox(height: 16),
          ReactiveTextField(
            formControlName: 'password',
            obscureText: true,
            decoration: _decoration(
              context,
              label: 'Password',
              icon: Icons.lock_outline,
            ),
          ),
          const SizedBox(height: 16),
          ReactiveTextField(
            formControlName: 'confirmPassword',
            obscureText: true,
            decoration: _decoration(
              context,
              label: 'Confirm Password',
              icon: Icons.lock_outline,
            ),
          ),
          const SizedBox(height: 24),
          ReactiveFormConsumer(
            builder: (context, form, child) {
              return Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed:
                      infoForm.valid
                          ? () => onStepContinueHandler(context)
                          : null,
                  child: const Text('Continue'),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
