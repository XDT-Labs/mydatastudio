import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/extensions/widget_extension.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/services/get_user_service.dart';
import 'package:mydatastudio/services/vault_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:form_builder_validators/form_builder_validators.dart';
import 'package:password_dart/password_dart.dart';
import 'package:path/path.dart' as p;

class LoginForm extends StatefulWidget {
  const LoginForm({super.key, this.onLoginSuccessful});
  final VoidCallback? onLoginSuccessful;

  @override
  State<LoginForm> createState() => _LoginFormState();
}

class _LoginFormState extends State<LoginForm> {
  final _formKey = GlobalKey<FormBuilderState>();
  AppLogger logger = AppLogger(null);
  bool isSubmitting = false;

  @override
  void initState() {
    super.initState();
    // No "remember me": the password is never persisted. It is entered on every
    // launch and used to unlock the credential vault (AUDIT M2).
    ServicesBinding.instance.keyboard.addHandler(onKey);
  }

  @override
  void dispose() {
    ServicesBinding.instance.keyboard.removeHandler(onKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 300,
      height: 300,
      child: Card(
        elevation: 5,
        surfaceTintColor: Colors.white70,
        child: Column(
          children: [
            const SizedBox(height: 64),
            // TODO add padding
            Container(
              padding: const EdgeInsets.all(16),
              child: FormBuilder(
                key: _formKey,
                child: Column(
                  children: [
                    FormBuilderTextField(
                      name: 'password',
                      autofocus: true,
                      decoration: const InputDecoration(labelText: 'Password'),
                      obscureText: true,
                      validator: FormBuilderValidators.compose([
                        FormBuilderValidators.required(),
                      ]),
                    ),
                    const SizedBox(height: 16),
                    MaterialButton(
                      onPressed:
                          !isSubmitting
                              ? () {
                                if (_formKey.currentState?.validate() ??
                                    false) {
                                  _formKey.currentState?.save();
                                  formSubmitHandler(
                                    context,
                                    _formKey.currentState?.instantValue ??
                                        {'password': null},
                                  );
                                }
                              }
                              : null,
                      child: const Text('Login'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Key listener to allow form submissing when users hits enter
  bool onKey(KeyEvent event) {
    final key = event.logicalKey.keyLabel;

    if (key == 'Enter') {
      if (_formKey.currentState?.validate() ?? false) {
        _formKey.currentState?.save();
        formSubmitHandler(
          null,
          _formKey.currentState?.instantValue ??
              {'password': null},
        );
      }
    }

    return false;
  }

  /// Unlock the credential vault (or create it on first login after this feature
  /// ships) from the just-entered plaintext password. Best-effort: a failure is
  /// logged but never blocks login — features needing secrets degrade until the
  /// vault is unlocked. See AUDIT.md M2.
  Future<void> _unlockVault(String password) async {
    final storagePath = MainApp.appDataDirectory.valueOrNull;
    if (storagePath == null || storagePath.isEmpty) return;
    final keysDir = p.join(storagePath, 'keys');
    try {
      if (await VaultManager.instance.vaultExists(keysDir)) {
        await VaultManager.instance.unlock(keysDir, password);
      } else {
        await VaultManager.instance.createAndUnlock(keysDir, password);
      }
    } catch (e) {
      logger.e('Vault unlock failed: $e');
    }
  }

  /// The formSubmitHandler function is used to handle form submissions
  ///
  /// Args:
  ///   context (BuildContext): The `context` parameter in the `formSubmitHandler` function is an object
  /// passed in from the build method
  Future<void> formSubmitHandler(
    BuildContext? context,
    Map<String, dynamic> values,
  ) async {
    if (context?.mounted ?? false) {
      setState(() {
        isSubmitting = true;
      });
    }

    try {
      String? pwd = values['password'];
      if (pwd != null) {
        var algorithm = PBKDF2(
          blockLength: 64,
          iterationCount: 10000,
          desiredKeyLength: 64,
        );
        var hash = Password.hash(pwd, algorithm);

        // Unlock the credential vault from the plaintext password BEFORE loading
        // the user: user() now reads keys/private.pem encrypted with the vault
        // DEK, so the vault must be unlocked first (AUDIT M2 phase 4). The
        // password itself is never persisted. A unlock failure is logged but not
        // fatal here — an actually-wrong password still fails the user lookup
        // below and shows "Wrong password".
        await _unlockVault(pwd);

        var dbUser = await GetUserService.instance.invoke(
          GetUserServiceCommand(hash),
        );
        if (dbUser != null) {
          widget.onLoginSuccessful!();
        } else {
          if (context != null && context.mounted) {
            context.showToast("Wrong password");
          }
        }
      }
    } catch (e) {
      logger.e("Login error: $e");
      if (context != null && context.mounted) {
        context.showToast("Login error: ${e.toString()}");
      }
    } finally {
      if (context?.mounted ?? false) {
        setState(() {
          isSubmitting = false;
        });
      }
    }
  }
}
