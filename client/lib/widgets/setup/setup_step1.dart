import 'package:mydatastudio/models/tables/app_user.dart';
import 'package:material_ui/material_ui.dart';
import 'package:password_dart/password_dart.dart';
import 'package:uuid/uuid.dart';

class SetupStep1 extends StatefulWidget {
  const SetupStep1({super.key, required this.onCancel, required this.onSubmit});

  final VoidCallback onCancel;
  final void Function(AppUser) onSubmit;

  @override
  State<SetupStep1> createState() => _SetupStep1State();
}

class _SetupStep1State extends State<SetupStep1> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  /// Whether Continue is offered.
  ///
  /// Read straight off the controllers rather than by calling
  /// `FormState.validate()`, which would paint every field's error the first
  /// time the button rebuilt — before the user has typed anything. The field
  /// validators below still own what the *messages* say; this only has to
  /// agree with them on the yes/no.
  bool get _isValid =>
      _name.text.trim().isNotEmpty &&
      _password.text.length >= 4 &&
      _confirmPassword.text.length >= 4 &&
      _password.text == _confirmPassword.text;

  void onStepContinueHandler(BuildContext context) {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    //Create User
    final name = _name.text;
    final password = _password.text;
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
    widget.onSubmit(appUser);
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

    return Form(
      key: _formKey,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      onChanged: () => setState(() {}),
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
          TextFormField(
            controller: _name,
            validator:
                (value) =>
                    (value == null || value.trim().isEmpty)
                        ? 'Name is required'
                        : null,
            decoration: _decoration(
              context,
              label: 'Name',
              icon: Icons.person_outline,
            ),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _password,
            obscureText: true,
            validator:
                (value) =>
                    (value == null || value.length < 4)
                        ? 'Password must be at least 4 characters'
                        : null,
            decoration: _decoration(
              context,
              label: 'Password',
              icon: Icons.lock_outline,
            ),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _confirmPassword,
            obscureText: true,
            validator: (value) {
              if (value == null || value.length < 4) {
                return 'Password must be at least 4 characters';
              }
              return value == _password.text ? null : 'Passwords must match';
            },
            decoration: _decoration(
              context,
              label: 'Confirm Password',
              icon: Icons.lock_outline,
            ),
          ),
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _isValid ? () => onStepContinueHandler(context) : null,
              child: const Text('Continue'),
            ),
          ),
        ],
      ),
    );
  }
}
