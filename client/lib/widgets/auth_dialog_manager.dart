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
        if (c.needsReAuth && c.type == 'email') {
          if (c.oauthService == 'google') {
            _showGoogleAuthDialog(c);
          } else if (c.oauthService == 'yahoo') {
            _showYahooAuthDialog(c);
          }
        }
      }
    });
  }

  void _showGoogleAuthDialog(Collection collection) {
    showDialog<SimpleDialog>(
      context: _globalNavigationKey.currentState!.context,
      builder: (BuildContext context) {
        return SimpleDialog(
          title: const Text('Authenticate Expired'),
          children: <Widget>[
            const SimpleDialogOption(
              onPressed: null,
              child: Text(
                "Your Google 'type' oauth token has expired or been reset for 'email'.\nClick button to re-authenticate.",
              ),
            ),
            SimpleDialogOption(
              onPressed: null,
              child: SizedBox(
                width: 225,
                height: 48,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.email),
                  label: const Text("Login with Google"),
                  onPressed: () async {
                    await LoginProviderExtension.handleGoogleMail(
                      context,
                      existing: collection,
                    );
                    // TODO close dialog
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showYahooAuthDialog(Collection collection) {
    showDialog<SimpleDialog>(
      context: _globalNavigationKey.currentState!.context,
      builder: (BuildContext context) {
        return SimpleDialog(
          title: const Text('Yahoo Authentication Expired'),
          children: <Widget>[
            SimpleDialogOption(
              onPressed: null,
              child: Text(
                "Your Yahoo token for '${collection.name}' has expired or been reset.\nClick button to re-authenticate.",
              ),
            ),
            SimpleDialogOption(
              child: SizedBox(
                width: 225,
                height: 48,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.email),
                  label: const Text("Login with Yahoo"),
                  onPressed: () async {
                    await LoginProviderExtension.handleYahooMail(
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
