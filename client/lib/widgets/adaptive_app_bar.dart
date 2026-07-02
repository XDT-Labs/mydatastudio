import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

class AdaptiveAppBar extends StatelessWidget implements PreferredSizeWidget {
  const AdaptiveAppBar({super.key, this.isDesktop = !kIsWeb});

  final bool isDesktop;

  @override
  Size get preferredSize => const Size(double.infinity, 64);

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
                    child: TextField(
                      style: TextStyle(
                        color: themeData.colorScheme.onSurface,
                        fontSize: 13,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Search files...',
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
