import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/services/get_collections_service.dart';
import 'package:mydatastudio/modules/social/widgets/social_drawer.dart';
import 'package:rxdart/rxdart.dart';

class FakeGetCollectionsService extends GetCollectionsService {
  final _isLoadingSubject = BehaviorSubject<bool>.seeded(false);
  final _sinkSubject = BehaviorSubject<List<Collection>>.seeded([]);

  @override
  BehaviorSubject<bool> get isLoading => _isLoadingSubject;

  @override
  BehaviorSubject<List<Collection>> get sink => _sinkSubject;

  @override
  Future<List<Collection>> invoke(GetCollectionsServiceCommand command) async {
    return _sinkSubject.value;
  }

  void setCollections(List<Collection> list) {
    _sinkSubject.add(list);
  }
}

void main() {
  group('SocialDrawer Widget Tests', () {
    late GetCollectionsService originalInstance;
    late FakeGetCollectionsService fakeService;

    setUp(() {
      SocialDrawer.resetState();
      originalInstance = GetCollectionsService.instance;
      fakeService = FakeGetCollectionsService();
      GetCollectionsService.instance = fakeService;
    });

    tearDown(() {
      GetCollectionsService.instance = originalInstance;
    });

    // Helper to build the SocialDrawer with a custom router
    Widget buildDrawer(GoRouter router) {
      return MaterialApp.router(
        routerConfig: router,
        theme: ThemeData(brightness: Brightness.light),
      );
    }

    testWidgets('renders Social Accounts header and accordions', (
      tester,
    ) async {
      final router = GoRouter(
        initialLocation: '/social',
        routes: [
          GoRoute(
            path: '/social',
            builder: (context, state) => const Scaffold(body: SocialDrawer()),
          ),
        ],
      );

      await tester.pumpWidget(buildDrawer(router));
      await tester.pumpAndSettle();

      // Check header
      expect(find.text('SOCIAL ACCOUNTS'), findsOneWidget);

      // Check accordions
      expect(find.text('Facebook Accounts'), findsOneWidget);
      expect(find.text('Twitter Accounts'), findsOneWidget);
      expect(find.text('Instagram Accounts'), findsOneWidget);
    });

    testWidgets(
      'Facebook accordion is expanded by default and renders mockups when collections empty',
      (tester) async {
        final router = GoRouter(
          initialLocation: '/social',
          routes: [
            GoRoute(
              path: '/social',
              builder: (context, state) => const Scaffold(body: SocialDrawer()),
            ),
          ],
        );

        await tester.pumpWidget(buildDrawer(router));
        await tester.pumpAndSettle();

        // Facebook should be expanded, showing mockup items
        expect(find.text('Meta Dev Team'), findsOneWidget);
        expect(find.text('Studio Primary'), findsOneWidget);
      },
    );

    testWidgets('renders active highlight and selection style based on path', (
      tester,
    ) async {
      final router = GoRouter(
        initialLocation: '/social/facebook/meta-dev-team',
        routes: [
          GoRoute(
            path: '/social',
            builder: (context, state) => const Scaffold(body: SocialDrawer()),
            routes: [
              GoRoute(
                path: 'facebook/:id',
                builder:
                    (context, state) => const Scaffold(body: SocialDrawer()),
              ),
            ],
          ),
        ],
      );

      await tester.pumpWidget(buildDrawer(router));
      await tester.pumpAndSettle();

      // Meta Dev Team is selected. Check its styling (bold font weight)
      final textWidget = tester.widget<Text>(find.text('Meta Dev Team'));
      expect(textWidget.style?.fontWeight, equals(FontWeight.bold));

      // Studio Primary is not selected. Check its styling (normal font weight)
      final unselectedTextWidget = tester.widget<Text>(
        find.text('Studio Primary'),
      );
      expect(unselectedTextWidget.style?.fontWeight, equals(FontWeight.normal));
    });

    testWidgets('triggers GoRouter navigation when mock item is tapped', (
      tester,
    ) async {
      final router = GoRouter(
        initialLocation: '/social',
        routes: [
          GoRoute(
            path: '/social',
            builder: (context, state) => const Scaffold(body: SocialDrawer()),
            routes: [
              GoRoute(
                path: 'facebook/:id',
                builder:
                    (context, state) => const Scaffold(body: SocialDrawer()),
              ),
            ],
          ),
        ],
      );

      await tester.pumpWidget(buildDrawer(router));
      await tester.pumpAndSettle();

      // Tap Studio Primary
      await tester.tap(find.text('Studio Primary'));
      await tester.pumpAndSettle();

      // Verify path updated to /social/facebook/studio-primary
      expect(
        router.routeInformationProvider.value.uri.path,
        equals('/social/facebook/studio-primary'),
      );
    });

    testWidgets('renders database social collections when present', (
      tester,
    ) async {
      final collections = <Collection>[
        Collection(
          id: 'fb-col-1',
          name: 'My Facebook Page',
          path: '',
          type: 'social',
          scanner: 'facebook',
          scanStatus: 'idle',
          needsReAuth: false,
        ),
        Collection(
          id: 'tw-col-1',
          name: 'Personal Twitter',
          path: '',
          type: 'social',
          scanner: 'twitter',
          scanStatus: 'idle',
          needsReAuth: false,
        ),
      ];
      fakeService.setCollections(collections);

      final router = GoRouter(
        initialLocation: '/social',
        routes: [
          GoRoute(
            path: '/social',
            builder: (context, state) => const Scaffold(body: SocialDrawer()),
            routes: [
              GoRoute(
                path: 'facebook/:id',
                builder:
                    (context, state) => const Scaffold(body: SocialDrawer()),
              ),
              GoRoute(
                path: 'twitter/:id',
                builder:
                    (context, state) => const Scaffold(body: SocialDrawer()),
              ),
            ],
          ),
        ],
      );

      await tester.pumpWidget(buildDrawer(router));
      await tester.pumpAndSettle();

      // Facebook accordion is expanded, should show the database facebook collection
      expect(find.text('My Facebook Page'), findsOneWidget);
      // Should NOT show the mockups
      expect(find.text('Meta Dev Team'), findsNothing);

      // Twitter accordion is collapsed by default. Let's tap to expand it.
      await tester.tap(find.text('Twitter Accounts'));
      await tester.pumpAndSettle();

      // Should show the database twitter collection
      expect(find.text('Personal Twitter'), findsOneWidget);
    });

    testWidgets(
      'renders FloatingActionButton and navigates to /social/add on tap',
      (tester) async {
        final router = GoRouter(
          initialLocation: '/social',
          routes: [
            GoRoute(
              path: '/social',
              builder: (context, state) => const Scaffold(body: SocialDrawer()),
              routes: [
                GoRoute(
                  path: 'add',
                  builder:
                      (context, state) =>
                          const Scaffold(body: Text('Add Social Source Page')),
                ),
              ],
            ),
          ],
        );

        await tester.pumpWidget(buildDrawer(router));
        await tester.pumpAndSettle();

        // Verify FAB is rendered
        final fabFinder = find.byType(FloatingActionButton);
        expect(fabFinder, findsOneWidget);

        // Verify styling of FAB
        final fab = tester.widget<FloatingActionButton>(fabFinder);
        expect(fab.tooltip, equals("Add Source"));
        expect(fab.shape, const CircleBorder());
        expect(find.byIcon(Icons.add), findsOneWidget);

        // Tap FAB
        await tester.tap(fabFinder);
        await tester.pumpAndSettle();

        // Verify routing happened
        expect(
          router.routeInformationProvider.value.uri.path,
          equals('/social/add'),
        );
      },
    );

    testWidgets(
      'preserves active accordion section when navigating to /social/add',
      (tester) async {
        final collections = <Collection>[
          Collection(
            id: 'tw-col-1',
            name: 'Personal Twitter',
            path: '',
            type: 'social',
            scanner: 'twitter',
            scanStatus: 'idle',
            needsReAuth: false,
          ),
        ];
        fakeService.setCollections(collections);

        // Setup a router with actual paths that uses the drawer at both routes
        final router = GoRouter(
          initialLocation: '/social/twitter/tw-col-1',
          routes: [
            GoRoute(
              path: '/social',
              builder: (context, state) => const Scaffold(body: SocialDrawer()),
              routes: [
                GoRoute(
                  path: 'twitter/:id',
                  builder:
                      (context, state) => const Scaffold(body: SocialDrawer()),
                ),
                GoRoute(
                  path: 'add',
                  builder:
                      (context, state) => const Scaffold(body: SocialDrawer()),
                ),
              ],
            ),
          ],
        );

        await tester.pumpWidget(buildDrawer(router));
        await tester.pumpAndSettle();

        // On /social/twitter/tw-col-1, the Twitter section should be expanded
        expect(find.text('Personal Twitter'), findsOneWidget);

        // Tap FAB to navigate to /social/add
        final fabFinder = find.byType(FloatingActionButton);
        await tester.tap(fabFinder);
        await tester.pumpAndSettle();

        // Verify the path updated to /social/add
        expect(
          router.routeInformationProvider.value.uri.path,
          equals('/social/add'),
        );

        // The Twitter section should STILL be expanded (and render the sub-item)
        expect(find.text('Personal Twitter'), findsOneWidget);
      },
    );
  });
}
