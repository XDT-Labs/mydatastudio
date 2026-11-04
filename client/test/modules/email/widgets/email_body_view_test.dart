import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/modules/email/services/email_body_preparer.dart';
import 'package:mydatastudio/modules/email/widgets/email_detail/email_body_view.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

const _htmlBody = PreparedEmailBody(
  html:
      '<html><head><title>Hidden title</title><style>.x{color:red}</style></head>'
      '<body><p>Visible text é</p></body></html>',
);

/// The tap's handler does real file and process I/O, which only completes
/// inside runAsync. Returns once the handler has reached the browser opener.
Future<void> _tapOpenInBrowser(WidgetTester tester, bool Function() reached) =>
    tester.runAsync(() async {
      await tester.tap(find.text('Open in browser'));
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!reached() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

void main() {
  test('Linux gets the HTML widget, other platforms the WebView', () {
    expect(
      EmailBodyView.forPlatform(_htmlBody, isLinux: true),
      isA<HtmlEmailBodyView>(),
    );
    expect(
      EmailBodyView.forPlatform(_htmlBody, isLinux: false),
      isA<WebViewEmailBodyView>(),
    );
  });

  group('HtmlEmailBodyView', () {
    testWidgets('shows the body but not the head or CSS', (tester) async {
      await tester.pumpWidget(_host(const HtmlEmailBodyView(body: _htmlBody)));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Visible text', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('Hidden title', findRichText: true),
        findsNothing,
      );
      expect(
        find.textContaining('color:red', findRichText: true),
        findsNothing,
      );
    });

    // The HTML widget ignores `white-space: pre-wrap`, so plain mail would
    // collapse into one paragraph if it went through it.
    testWidgets('plain mail keeps its line breaks, with nothing to open', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const HtmlEmailBodyView(
            body: PreparedEmailBody(
              html: '<html></html>',
              plainText: 'one\ntwo',
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('one\ntwo'), findsOneWidget);
      expect(find.byType(HtmlWidget), findsNothing);
      expect(find.text('Open in browser'), findsNothing);
    });

    test('images can only come from data: or the network', () {
      final factory = EmailHtmlWidgetFactory();
      expect(
        factory.imageProviderFromFileUri('file:///etc/secret.png'),
        isNull,
      );
      expect(factory.imageProviderFromAsset('asset:assets/logo.png'), isNull);
      expect(factory.imageProviderFromNetwork('blocked:x'), isNull);
      expect(factory.imageProviderFromNetwork('https://x/a.png'), isNotNull);
      expect(factory.imageProviderFromNetwork('http://x/a.png'), isNotNull);
    });

    testWidgets('links open externally, only for web and mail schemes', (
      tester,
    ) async {
      final opened = <Uri>[];
      await tester.pumpWidget(
        _host(
          HtmlEmailBodyView(
            body: _htmlBody,
            openLink: (url) async {
              opened.add(url);
              return true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final onTap =
          tester.widget<HtmlWidget>(find.byType(HtmlWidget)).onTapUrl!;
      for (final url in [
        'https://x/',
        'mailto:a@b.c',
        'file:///etc/passwd',
        'blocked:steal()',
        'smb://host/share',
      ]) {
        // Handled either way: the widget has no fallback of its own to reach.
        expect(await onTap(url), isTrue);
      }

      expect(opened.map((u) => u.scheme), ['https', 'mailto']);
    });

    testWidgets(
      'Open in browser gets a private UTF-8 copy of the sanitised HTML',
      (tester) async {
        String? openedPath;
        await tester.pumpWidget(
          _host(
            HtmlEmailBodyView(
              body: _htmlBody,
              openInBrowser: (path) async {
                openedPath = path;
                return true;
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _tapOpenInBrowser(tester, () => openedPath != null);
        await tester.pump();

        await tester.runAsync(() async {
          final file = io.File(openedPath!);
          final bytes = await file.readAsBytes();
          expect(bytes.take(3), [0xEF, 0xBB, 0xBF]);
          expect(await file.readAsString(), contains('Visible text é'));
          if (!io.Platform.isWindows) {
            final mode = (await file.parent.stat()).mode & 0x3F;
            expect(mode, 0, reason: 'Only this user may read the mail copy');
          }
        });
        expect(find.text('Could not open browser'), findsNothing);
      },
    );

    testWidgets('says so when the browser cannot be opened', (tester) async {
      var reached = false;
      await tester.pumpWidget(
        _host(
          HtmlEmailBodyView(
            body: _htmlBody,
            openInBrowser: (_) async {
              reached = true;
              throw const io.ProcessException('xdg-open', [], 'not found');
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _tapOpenInBrowser(tester, () => reached);
      await tester.pump();
      await tester.pump();

      expect(find.text('Could not open browser'), findsOneWidget);
    });
  });
}
