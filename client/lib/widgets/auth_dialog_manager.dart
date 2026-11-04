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
        if (c.needsReAuth && c.oauthService == 'google' && c.type != 'email') {
          _showGoogleAuthDialog(c);
        }
      }
    });
  }

  void _showGoogleAuthDialog(Collection collection) {

    showDialog<SimpleDialog>(
      context: _globalNavigationKey.currentState!.context,
      builder: (BuildContext context) {
        return SimpleDialog(
          title: const Text('Authentication Expired'),
          children: <Widget>[
            SimpleDialogOption(
              onPressed: null,
              child: Text(
                "Your Google OAuth token has expired or been revoked for 'Google Drive'.\nClick the button to re-authenticate.",
              ),
            ),
            SimpleDialogOption(
              onPressed: null,
              child: SizedBox(
                width: 225,
                height: 48,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.cloud),
                  label: const Text("Login with Google (Google Drive)"),
                  onPressed: () async {
                    await LoginProviderExtension.handleGoogleDrive(
                      context,
                      existing: collection,
                    );
                    if (context.mounted) {
                      Navigator.of(context).pop();
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
