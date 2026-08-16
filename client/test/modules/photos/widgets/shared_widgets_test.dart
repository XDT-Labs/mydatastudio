import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/color_schemes.g.dart';
import 'package:mydatastudio/modules/photos/widgets/dialogs/keyboard_shortcuts_modal.dart';
import 'package:mydatastudio/modules/photos/widgets/drawer/drawer_nav_item.dart';
import 'package:mydatastudio/modules/photos/widgets/drawer/drawer_section.dart';
import 'package:mydatastudio/modules/photos/widgets/drawer/storage_meter.dart';
import 'package:mydatastudio/modules/photos/widgets/drawer/tag_chip.dart';
import 'package:mydatastudio/modules/photos/widgets/sidebar/animated_info_panel.dart';
import 'package:mydatastudio/modules/photos/widgets/tiles/date_section_header.dart';
import 'package:mydatastudio/modules/photos/widgets/toolbar/filter_dropdown.dart';

Widget createTestApp(Widget child) {
  return MaterialApp(
    theme: ThemeData(useMaterial3: true, colorScheme: darkColorScheme),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  group('DrawerSection', () {
    testWidgets('renders title, icon, child, and toggles expand/collapse', (
      tester,
    ) async {
      await tester.pumpWidget(
        createTestApp(
          const DrawerSection(
            title: 'Library',
            icon: Icons.photo_library,
            initiallyExpanded: true,
            trailing: Text('Trailing'),
            child: Text('Section Content'),
          ),
        ),
      );

      expect(find.text('Library'), findsOneWidget);
      expect(find.byIcon(Icons.photo_library), findsOneWidget);
      expect(find.text('Trailing'), findsOneWidget);
      expect(find.text('Section Content'), findsOneWidget);

      // Tap header to collapse
      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();
      final crossFade = tester.widget<AnimatedCrossFade>(
        find.byType(AnimatedCrossFade),
      );
      expect(crossFade.crossFadeState, equals(CrossFadeState.showSecond));

      // Tap header to re-expand
      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();
      expect(find.text('Section Content'), findsOneWidget);
    });
  });

  group('DrawerNavItem', () {
    testWidgets('renders label, icon, count badge and handles tap callbacks', (
      tester,
    ) async {
      bool tapped = false;
      bool secondaryTapped = false;

      await tester.pumpWidget(
        createTestApp(
          DrawerNavItem(
            label: 'Favorites',
            icon: Icons.favorite,
            count: 42,
            isActive: true,
            onTap: () => tapped = true,
            onSecondaryAction: () => secondaryTapped = true,
          ),
        ),
      );

      expect(find.text('Favorites'), findsOneWidget);
      expect(find.byIcon(Icons.favorite), findsOneWidget);
      expect(find.text('42'), findsOneWidget);

      await tester.tap(find.text('Favorites'));
      expect(tapped, isTrue);

      await tester.tap(find.byIcon(Icons.delete_outline));
      expect(secondaryTapped, isTrue);
    });
  });

  group('StorageMeter', () {
    test('formatBytes formats sizes accurately', () {
      expect(StorageMeter.formatBytes(0), '0 B');
      expect(StorageMeter.formatBytes(512), '512 B');
      expect(StorageMeter.formatBytes(1024 * 500), '500 KB');
      expect(StorageMeter.formatBytes(1288490188), '1.2 GB');
      expect(StorageMeter.formatBytes(2199023255552), '2 TB');
    });

    testWidgets('renders progress bar and formatted string', (tester) async {
      await tester.pumpWidget(
        createTestApp(
          const StorageMeter(usedBytes: 1288490188, totalBytes: 2199023255552),
        ),
      );

      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('1.2 GB of 2 TB'), findsOneWidget);
    });
  });

  group('TagChip', () {
    testWidgets('renders tag label with count and handles tap & remove', (
      tester,
    ) async {
      bool tapped = false;
      bool removed = false;

      await tester.pumpWidget(
        createTestApp(
          TagChip(
            tag: 'vacation',
            count: 15,
            isActive: false,
            onTap: () => tapped = true,
            onRemove: () => removed = true,
          ),
        ),
      );

      expect(find.text('#vacation (15)'), findsOneWidget);

      await tester.tap(find.text('#vacation (15)'));
      expect(tapped, isTrue);

      await tester.tap(find.byIcon(Icons.close));
      expect(removed, isTrue);
    });
  });

  group('DateSectionHeader', () {
    testWidgets('renders date label, item count, and select all checkbox', (
      tester,
    ) async {
      bool? selectedState;

      await tester.pumpWidget(
        createTestApp(
          DateSectionHeader(
            dateLabel: 'Saturday, July 12, 2026',
            itemCount: 8,
            isSelected: false,
            onSelectAll: (val) => selectedState = val,
          ),
        ),
      );

      expect(find.text('Saturday, July 12, 2026'), findsOneWidget);
      expect(find.text('8 items'), findsOneWidget);
      expect(find.byType(Checkbox), findsOneWidget);

      await tester.tap(find.byType(Checkbox));
      expect(selectedState, isTrue);
    });
  });

  group('AnimatedInfoPanel', () {
    testWidgets('occupies its full width when open', (tester) async {
      await tester.pumpWidget(
        createTestApp(
          const AnimatedInfoPanel(
            isOpen: true,
            width: 320,
            child: Text('Panel Content'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Panel Content'), findsOneWidget);
      expect(tester.getSize(find.byType(AnimatedInfoPanel)).width, 320);
    });

    testWidgets('takes no width when closed', (tester) async {
      await tester.pumpWidget(
        createTestApp(
          const AnimatedInfoPanel(
            isOpen: false,
            width: 320,
            child: Text('Panel Content'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.getSize(find.byType(AnimatedInfoPanel)).width, 0);
    });

    testWidgets(
      'grows from the right edge so the panel slides in beside the content',
      (tester) async {
        // The panel used to size from its left edge, which drew it in its
        // final position on the first frame and then wiped it into view —
        // reading as the sidebar landing on top of the grid rather than
        // arriving next to it. Anchoring right is what the Files module's
        // details drawer does.
        // Laid out the way PhotosApp lays it out — pinned to the right of the
        // view it shares a Row with — since that is what makes "which edge
        // moves" observable at all.
        Widget alongsideContent({required bool isOpen}) => createTestApp(
          SizedBox(
            width: 800,
            height: 600,
            child: Row(
              children: [
                const Expanded(child: SizedBox.expand()),
                AnimatedInfoPanel(
                  isOpen: isOpen,
                  width: 320,
                  child: const Text('Panel Content'),
                ),
              ],
            ),
          ),
        );

        await tester.pumpWidget(alongsideContent(isOpen: false));
        await tester.pumpAndSettle();

        final closedRight = tester.getTopRight(find.byType(AnimatedInfoPanel));

        await tester.pumpWidget(alongsideContent(isOpen: true));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 125));

        // Mid-animation the right edge has not moved; only the left one has.
        expect(
          tester.getTopRight(find.byType(AnimatedInfoPanel)).dx,
          closeTo(closedRight.dx, 0.5),
        );
        final midWidth = tester.getSize(find.byType(AnimatedInfoPanel)).width;
        expect(midWidth, greaterThan(0));
        expect(midWidth, lessThan(320));
      },
    );
  });

  group('KeyboardShortcutsModal', () {
    testWidgets('renders shortcuts dialog and closes on button tap', (
      tester,
    ) async {
      await tester.pumpWidget(
        createTestApp(
          Builder(
            builder:
                (context) => ElevatedButton(
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (_) => const KeyboardShortcutsModal(),
                    );
                  },
                  child: const Text('Open Dialog'),
                ),
          ),
        ),
      );

      await tester.tap(find.text('Open Dialog'));
      await tester.pumpAndSettle();

      expect(find.text('Keyboard Shortcuts'), findsOneWidget);
      expect(find.text('Space'), findsOneWidget);
      expect(find.text('View photo fullscreen'), findsOneWidget);
      expect(find.text('Ctrl+A'), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      expect(find.text('Keyboard Shortcuts'), findsNothing);
    });
  });

  group('FilterDropdown', () {
    testWidgets(
      'renders popup menu button and handles callbacks on selection',
      (tester) async {
        String? updatedMediaType;
        bool? updatedFavorites;
        String? updatedSort;

        await tester.pumpWidget(
          createTestApp(
            FilterDropdown(
              mediaType: null,
              onlyFavorites: false,
              sortBy: 'dateDesc',
              onMediaTypeChanged: (val) => updatedMediaType = val,
              onFavoritesChanged: (val) => updatedFavorites = val,
              onSortChanged: (val) => updatedSort = val,
            ),
          ),
        );

        expect(find.byIcon(Icons.filter_list), findsOneWidget);

        // Open popup menu
        await tester.tap(find.byIcon(Icons.filter_list));
        await tester.pumpAndSettle();

        expect(find.text('MEDIA TYPE'), findsOneWidget);
        expect(find.text('Photos'), findsOneWidget);
        expect(find.text('Favorites Only'), findsOneWidget);
        expect(find.text('SORT BY'), findsOneWidget);
        expect(find.text('Oldest'), findsOneWidget);

        // Select Photos
        await tester.tap(find.text('Photos'));
        await tester.pumpAndSettle();
        expect(updatedMediaType, 'photo');

        // Re-open popup menu and select Favorites Only
        await tester.tap(find.byIcon(Icons.filter_list));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Favorites Only'));
        await tester.pumpAndSettle();
        expect(updatedFavorites, isTrue);

        // Re-open popup menu and select Oldest
        await tester.tap(find.byIcon(Icons.filter_list));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Oldest'));
        await tester.pumpAndSettle();
        expect(updatedSort, 'dateAsc');
      },
    );
  });
}
