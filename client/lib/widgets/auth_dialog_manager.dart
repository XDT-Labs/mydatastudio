import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/oauth/login_providers.dart';
import 'package:mydatastudio/services/get_collections_service.dart';
import 'package:material_ui/material_ui.dart';

class AuthDialogManager {
  AuthDialogManager(this._globalNavigationKey);

  final GlobalKey<NavigatorState> _globalNavigationKey;

  void init() {
    GetCollectionsService.instance.sink.listen((value) {
      for (var c in value) {
        if (c.needsReAuth &&
            (c.oauthService == 'google' ||
                c.oauthService == 'dropbox' ||
                c.oauthService == 'onedrive')) {
          _showAuthDialog(c);
        }
      }
    });
  }

  void _showAuthDialog(Collection collection) {
    final isDropbox = collection.oauthService == 'dropbox';
    final isOneDrive = collection.oauthService == 'onedrive';
    final isEmail = collection.type == 'email';
    final typeLabel =
        isDropbox
            ? 'Dropbox'
            : isOneDrive
            ? 'OneDrive'
            : (isEmail ? 'Gmail' : 'Google Drive');
    final icon = isEmail ? Icons.email : Icons.cloud;
    final message =
        isDropbox
            ? "Your Dropbox sign-in has expired or been revoked.\nClick the button to sign in again."
            : isOneDrive
            ? "Your OneDrive sign-in has expired or been revoked.\nClick the button to sign in again."
            : "Your Google OAuth token has expired or been revoked for '$typeLabel'.\nClick the button to re-authenticate.";
    final buttonLabel =
        isDropbox
            ? 'Sign in to Dropbox'
            : isOneDrive
            ? 'Sign in to OneDrive'
            : 'Login with Google ($typeLabel)';

    showDialog<SimpleDialog>(
      context: _globalNavigationKey.currentState!.context,
      builder: (BuildContext context) {
        return SimpleDialog(
          title: const Text('Authentication Expired'),
          children: <Widget>[
            SimpleDialogOption(onPressed: null, child: Text(message)),
            SimpleDialogOption(
              onPressed: null,
              child: SizedBox(
                width: 225,
                height: 48,
                child: ElevatedButton.icon(
                  icon: Icon(icon),
                  label: Text(buttonLabel),
                  onPressed: () async {
                    // Close first: sign-in happens in the browser, and the
                    // dialog's context dies with it, so handlers get the
                    // navigator's.
                    final navContext =
                        _globalNavigationKey.currentState!.context;
                    Navigator.of(context).pop();
                    try {
                      if (isDropbox) {
                        await LoginProviderExtension.handleDropbox(
                          navContext,
                          existing: collection,
                        );
                      } else if (isOneDrive) {
                        await LoginProviderExtension.handleOneDrive(
                          navContext,
                          existing: collection,
                        );
                      } else if (isEmail) {
                        await LoginProviderExtension.handleGoogleMail(
                          navContext,
                          existing: collection,
                        );
                      } else {
                        await LoginProviderExtension.handleGoogleDrive(
                          navContext,
                          existing: collection,
                        );
                      }
                    } catch (e) {
                      // e.g. OneDrive's "admin consent required" message.
                      if (!navContext.mounted) return;
                      ScaffoldMessenger.of(navContext).showSnackBar(
                        SnackBar(
                          content: Text(
                            e.toString().replaceFirst('Exception: ', ''),
                          ),
                        ),
                      );
                    }
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
