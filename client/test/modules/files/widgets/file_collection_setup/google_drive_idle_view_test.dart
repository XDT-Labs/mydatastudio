import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/google_drive_idle_view.dart';
import 'package:mydatastudio/scanners/cloud/content_policy.dart';

void main() {
  // The policy controls make the card taller than the default 800x600 surface.
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1000, 1800);
    view.devicePixelRatio = 1;
    addTearDown(view.resetPhysicalSize);
    addTearDown(view.resetDevicePixelRatio);
  });

  group('GoogleDriveIdleView', () {
    testWidgets('shows Connect Google Drive heading', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GoogleDriveIdleView(
              onConnect: () {},
              policy: ContentPolicy.everything,
              onPolicyChanged: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('Connect Google Drive'), findsOneWidget);
    });

    testWidgets('shows scope notice', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GoogleDriveIdleView(
              onConnect: () {},
              policy: ContentPolicy.everything,
              onPolicyChanged: (_) {},
            ),
          ),
        ),
      );

      expect(find.textContaining('Drive access'), findsOneWidget);
    });

    testWidgets('Cancel button is NOT present', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GoogleDriveIdleView(
              onConnect: () {},
              policy: ContentPolicy.everything,
              onPolicyChanged: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('Cancel'), findsNothing);
    });

    testWidgets('sign in button calls onConnect', (tester) async {
      bool called = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GoogleDriveIdleView(
              onConnect: () => called = true,
              policy: ContentPolicy.everything,
              onPolicyChanged: (_) {},
            ),
          ),
        ),
      );

      await tester.tap(find.text('Sign in with Google'));
      await tester.pump();

      expect(called, isTrue);
    });

    testWidgets('unchecking a category reports a policy without it', (
      tester,
    ) async {
      ContentPolicy? last;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: GoogleDriveIdleView(
                onConnect: () {},
                policy: ContentPolicy.everything,
                onPolicyChanged: (v) => last = v,
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('category-videos')));
      await tester.pump();

      expect(last!.downloadCategories, isNot(contains(ContentCategory.videos)));
      expect(last!.downloadCategories, contains(ContentCategory.images));
    });

    testWidgets('keep-deleted switch defaults off and reports toggles', (
      tester,
    ) async {
      bool? changed;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GoogleDriveIdleView(
              onConnect: () {},
              policy: ContentPolicy.everything,
              onPolicyChanged: (_) {},
              onKeepDeletedFilesChanged: (v) => changed = v,
            ),
          ),
        ),
      );
      final sw = find.widgetWithText(
        SwitchListTile,
        'Keep files deleted from Google Drive',
      );
      expect(tester.widget<SwitchListTile>(sw).value, isFalse);
      await tester.tap(sw);
      expect(changed, isTrue);
    });
  });
}
