import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/widgets/collapsing_drawer.dart';

/// The rail highlight used to be remembered from the last tap, so anything
/// that navigated without going through the rail — the Photos sidebar linking
/// an attachment to its email, logout, a sub-route — left it pointing at a
/// module the user was no longer in.
void main() {
  // Home, divider, Files, Photos, AI Chat, divider, Email.
  const routes = <String?>[
    '/',
    null,
    '/files',
    '/photos',
    '/aichat',
    null,
    '/email',
  ];

  group('selectedRailIndexFor', () {
    test('selects the module whose route is showing', () {
      expect(selectedRailIndexFor('/email', routes), 6);
      expect(selectedRailIndexFor('/photos', routes), 3);
    });

    test('keeps the module selected on its sub-routes', () {
      // /photos/albums/1 and /files/add are still Photos and Files; the rail
      // going blank there would read as a bug.
      expect(selectedRailIndexFor('/photos/albums/abc', routes), 3);
      expect(selectedRailIndexFor('/files/add', routes), 2);
    });

    test('Home matches only itself', () {
      // '/' prefixes every route in the app, so a naive startsWith would
      // light up Home everywhere.
      expect(selectedRailIndexFor('/', routes), 0);
      expect(selectedRailIndexFor('/email', routes), isNot(0));
    });

    test('selects nothing for a route that is not in the rail', () {
      // Settings is reached from the app bar, not the rail. Leaving the last
      // module highlighted there is the same lie as before.
      expect(selectedRailIndexFor('/settings', routes), isNull);
      expect(selectedRailIndexFor('/settings/credits', routes), isNull);
      expect(selectedRailIndexFor('/login', routes), isNull);
    });

    test('does not match a route that merely shares a prefix', () {
      const withSibling = <String?>['/', '/file', '/files'];

      // '/files' must not select the '/file' entry.
      expect(selectedRailIndexFor('/files', withSibling), 2);
      expect(selectedRailIndexFor('/file', withSibling), 1);
    });

    test('prefers the longest matching route', () {
      const nested = <String?>['/', '/files', '/files/photos'];

      expect(selectedRailIndexFor('/files/photos/x', nested), 2);
    });

    test('never selects a divider', () {
      for (final location in ['/', '/files', '/photos', '/email', '/nope']) {
        final index = selectedRailIndexFor(location, routes);
        if (index != null) expect(routes[index], isNotNull);
      }
    });
  });
}
