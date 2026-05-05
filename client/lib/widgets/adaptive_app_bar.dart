import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class AdaptiveAppBar extends StatelessWidget implements PreferredSizeWidget {
  const AdaptiveAppBar({
    super.key,
    this.isDesktop = !kIsWeb,
  });

  final bool isDesktop;

  @override
  Size get preferredSize => const Size(300, 72);

  @override
  Widget build(BuildContext context) {
    final themeData = Theme.of(context);
    return PreferredSize(
      preferredSize: const Size.fromHeight(64.0), // GCP is a bit shorter
      child: Container(
        decoration: BoxDecoration(
          color: themeData.scaffoldBackgroundColor, // Match the gray background
        ),
        child: AppBar(
          toolbarHeight: 64,
          centerTitle: false,
          automaticallyImplyLeading: false,
          title: Text(
            'My Data', 
            style: themeData.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w400,
              color: Colors.black87,
            ),
          ),
          backgroundColor: Colors.transparent,
          elevation: 0,
          actions: [
            IconButton(
              icon: const Icon(Icons.settings, color: Colors.black54),
              tooltip: 'User Settings',
              onPressed: () {
                GoRouter.of(context).push('/settings');
              },
            ),
          ],
        ),
      ),
    );
  }
}
