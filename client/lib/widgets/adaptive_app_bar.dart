import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/search/services/suggestions/field_suggestion_service.dart';
import 'package:mydatastudio/modules/search/widgets/search_field.dart';

class AdaptiveAppBar extends StatefulWidget implements PreferredSizeWidget {
  const AdaptiveAppBar({super.key, this.isDesktop = !kIsWeb, this.suggestions});

  final bool isDesktop;

  /// Injection seam for widget tests, which have no database behind them.
  /// In the app this is built from the open archive in [State.initState].
  final FieldSuggestionService? suggestions;

  @override
  Size get preferredSize => const Size(double.infinity, 64);

  @override
  State<AdaptiveAppBar> createState() => _AdaptiveAppBarState();
}

class _AdaptiveAppBarState extends State<AdaptiveAppBar> {
  /// Owned here rather than by the `TextField` so the completion overlay can
  /// read the caret position and rewrite the value under it.
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  /// Null when there is no database yet, in which case the header field still
  /// works and simply offers no completions.
  FieldSuggestionService? _suggestions;

  @override
  void initState() {
    super.initState();
    _suggestions = widget.suggestions;
    if (_suggestions != null) return;
    final database = DatabaseManager.instance.database;
    if (database != null) {
      _suggestions = FieldSuggestionService.forDatabase(database);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onSubmitted(String value) {
    final query = value.trim();
    if (query.isEmpty) return;
    GoRouter.of(context).push('/search?q=${Uri.encodeQueryComponent(query)}');
  }

  @override
  Widget build(BuildContext context) {
    final themeData = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: themeData.colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: themeData.colorScheme.outlineVariant.withOpacity(0.5),
            width: 0.5,
          ),
        ),
      ),
      child: AppBar(
        toolbarHeight: 64,
        centerTitle: false,
        automaticallyImplyLeading: false,
        titleSpacing: 24,
        title: Row(
          children: [
            Text(
              'MyData Studio',
              style: GoogleFonts.montserrat(
                fontWeight: FontWeight.w200,
                fontSize: 22,
                color: themeData.colorScheme.primary,
                letterSpacing: -0.5,
              ),
            ),
            const Spacer(),
            // Search Bar
            Container(
              width: 280,
              height: 36,
              decoration: BoxDecoration(
                color: themeData.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: themeData.colorScheme.outlineVariant.withOpacity(0.5),
                  width: 1,
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(
                    Icons.search,
                    size: 16,
                    color: themeData.colorScheme.onSurfaceVariant.withOpacity(
                      0.6,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    // Completion belongs here too, not just on the search
                    // page: this field is where a query is composed from
                    // wherever you happen to be, so it is the one that most
                    // needs `from:` and `tag:` to be pickable rather than
                    // guessed. Landing on the results page to discover the
                    // filter matched nothing is the exact failure §13 exists
                    // to remove.
                    child: SearchFieldCompletion(
                      controller: _controller,
                      focusNode: _focusNode,
                      onSubmitted: _onSubmitted,
                      suggestions: _suggestions,
                      fieldBuilder:
                          (context, controller, focusNode, onSubmitted) =>
                              TextField(
                                controller: controller,
                                focusNode: focusNode,
                                style: TextStyle(
                                  color: themeData.colorScheme.onSurface,
                                  fontSize: 13,
                                ),
                                textInputAction: TextInputAction.search,
                                // Search is reached from here rather than from
                                // a nav entry: this field is already present on
                                // every screen, and search is something you
                                // invoke from wherever you are, not a place you
                                // navigate to.
                                onSubmitted: onSubmitted,
                                decoration: InputDecoration(
                                  hintText: 'Search everything...',
                                  hintStyle: TextStyle(
                                    color: themeData.colorScheme.onSurfaceVariant
                                        .withOpacity(0.6),
                                    fontSize: 13,
                                  ),
                                  border: InputBorder.none,
                                  isDense: true,
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          IconButton(
            icon: Icon(
              Icons.notifications_outlined,
              color: themeData.colorScheme.onSurface,
              size: 22,
            ),
            tooltip: 'Notifications',
            onPressed: () {},
          ),
          IconButton(
            icon: Icon(
              Icons.settings_outlined,
              color: themeData.colorScheme.onSurface,
              size: 22,
            ),
            tooltip: 'User Settings',
            onPressed: () {
              GoRouter.of(context).push('/settings');
            },
          ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(right: 24.0),
            child: CircleAvatar(
              radius: 16,
              backgroundImage: const AssetImage('assets/profile_avatar.png'),
              backgroundColor: themeData.colorScheme.primaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}
