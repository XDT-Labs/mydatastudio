import 'package:mydatatools/widgets/adaptive_app_bar.dart';
import 'package:mydatatools/widgets/collapsing_drawer.dart';
import 'package:mydatatools/widgets/router/status_message.dart';
import 'package:flutter/material.dart';

class NavigationWrapper extends StatefulWidget {
  const NavigationWrapper({super.key, required this.body, this.drawer});

  final Widget body;
  final Widget? drawer;

  @override
  State<NavigationWrapper> createState() => _NavigationWrapperState();
}

class _NavigationWrapperState extends State<NavigationWrapper> {
  final GlobalKey<ScaffoldState> appScaffold = GlobalKey<ScaffoldState>();

  final bool _drawerOpen = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      key: appScaffold,
      appBar: const AdaptiveAppBar(),
      body: Column(
        children: <Widget>[
          Expanded(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CollapsingDrawer(),

                Expanded(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      (_drawerOpen && widget.drawer != null)
                          ? Container(
                              width: 250, 
                              decoration: BoxDecoration(
                                color: Colors.white,
                              ),
                              child: widget.drawer,
                            )
                          : Container(),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(16), // effectively increasing spacing
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface, 
                          ),
                          child: Container(
                            clipBehavior: Clip.antiAlias,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerLowest,
                              borderRadius: BorderRadius.circular(8), // md roundedness
                              boxShadow: [
                                BoxShadow(
                                  color: theme.colorScheme.shadow,
                                  blurRadius: 8.0, // extra-diffused shadow
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: widget.body,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 22,
            child: Container(
              padding: const EdgeInsets.only(left: 16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest, // optional subtle separation
              ),
              child: const Row(children: [StatusMessage()]),
            ),
          ),
        ],
      ),
    );
  }
}
