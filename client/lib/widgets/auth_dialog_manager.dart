import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/oauth/login_providers.dart';
import 'package:mydatatools/services/get_collections_service.dart';
import 'package:flutter/material.dart';

class AuthDialogManager {
  AuthDialogManager(this._globalNavigationKey);

  final GlobalKey<NavigatorState> _globalNavigationKey;

  void init() {
    GetCollectionsService.instance.sink.listen((value) {
      for (var c in value) {
        if (c.needsReAuth && c.oauthService == 'google') {
          _showGoogleAuthDialog(c);
        }
      }
    });
  }

  void _showGoogleAuthDialog(Collection collection) {
    final isEmail = collection.type == 'email';
    final typeLabel = isEmail ? 'Gmail' : 'Google Drive';
    final icon = isEmail ? Icons.email : Icons.cloud;

    showDialog<SimpleDialog>(
      context: _globalNavigationKey.currentState!.context,
      builder: (BuildContext context) {
        return SimpleDialog(
          title: const Text('Authentication Expired'),
          children: <Widget>[
            SimpleDialogOption(
              onPressed: null,
              child: Text(
                "Your Google OAuth token has expired or been revoked for '$typeLabel'.\nClick the button to re-authenticate.",
              ),
            ),
            SimpleDialogOption(
              onPressed: null,
              child: SizedBox(
                width: 225,
                height: 48,
                child: ElevatedButton.icon(
                  icon: Icon(icon),
                  label: Text("Login with Google ($typeLabel)"),
                  onPressed: () async {
                    if (isEmail) {
                      await LoginProviderExtension.handleGoogleMail(
                        context,
                        existing: collection,
                      );
                    } else {
                      await LoginProviderExtension.handleGoogleDrive(
                        context,
                        existing: collection,
                      );
                    }
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
