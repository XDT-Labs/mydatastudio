import 'dart:io' as io;

import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/modules/email/services/email_body_preparer.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Renders a [PreparedEmailBody]; there is one implementation per platform.
abstract interface class EmailBodyView implements Widget {
  PreparedEmailBody get body;

  factory EmailBodyView.forPlatform(
    PreparedEmailBody body, {
    @visibleForTesting bool? isLinux,
  }) =>
      (isLinux ?? io.Platform.isLinux)
          ? HtmlEmailBodyView(body: body)
          : WebViewEmailBodyView(body: body);
}

/// The system WebView, on the platforms `webview_flutter` supports.
class WebViewEmailBodyView extends StatefulWidget implements EmailBodyView {
  const WebViewEmailBodyView({super.key, required this.body});

  @override
  final PreparedEmailBody body;

  @override
  State<WebViewEmailBodyView> createState() => _WebViewEmailBodyViewState();
}

class _WebViewEmailBodyViewState extends State<WebViewEmailBodyView> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()..loadHtmlString(widget.body.html);
  }

  @override
  void didUpdateWidget(WebViewEmailBodyView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.body.html != widget.body.html) {
      _controller.loadHtmlString(widget.body.html);
    }
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);
}

/// Stands in for the WebView's CSP, which [HtmlWidget] doesn't read: images may
/// only come from `data:` or the network, never from local files or the app's
/// own assets, so a message can't pull anything off the disk.
@visibleForTesting
class EmailHtmlWidgetFactory extends WidgetFactory {
  @override
  ImageProvider? imageProviderFromAsset(String url) => null;

  @override
  ImageProvider? imageProviderFromFileUri(String url) => null;

  @override
  ImageProvider? imageProviderFromNetwork(String url) {
    final scheme = Uri.tryParse(url)?.scheme;
    return scheme == 'http' || scheme == 'https'
        ? super.imageProviderFromNetwork(url)
        : null;
  }
}

/// Pure-Dart rendering for Linux, which has no `webview_flutter`
/// implementation. Scripts never run, and it needs no browser engine, so it
/// also works in the NAS container. Newsletters lose their `<style>` rules
/// here, which is what **Open in browser** is for.
class HtmlEmailBodyView extends StatelessWidget implements EmailBodyView {
  const HtmlEmailBodyView({
    super.key,
    required this.body,
    @visibleForTesting this.openInBrowser = _xdgOpen,
    @visibleForTesting this.openLink = launchUrl,
  });

  @override
  final PreparedEmailBody body;

  /// Opens a local file in the browser; false if that failed.
  final Future<bool> Function(String path) openInBrowser;

  final Future<bool> Function(Uri url) openLink;

  static const _linkSchemes = {'http', 'https', 'mailto'};

  /// One per run, reused so a session leaves at most one message on disk.
  static io.Directory? _browserCopyDir;

  /// `mktemp` because `Directory.createTemp` honours the umask on Linux, which
  /// would leave the user's mail readable by everyone on the machine.
  static Future<io.Directory> _createPrivateDir() async {
    final template = p.join(
      io.Directory.systemTemp.path,
      'mydatastudio_email_XXXXXXXX',
    );
    final result = await io.Process.run('mktemp', ['-d', template]);
    if (result.exitCode != 0) {
      throw io.FileSystemException('mktemp failed', template);
    }
    return io.Directory((result.stdout as String).trim());
  }

  static Future<bool> _xdgOpen(String path) async =>
      (await io.Process.run('xdg-open', [path])).exitCode == 0;

  Future<bool> _handleLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null && _linkSchemes.contains(uri.scheme)) {
      await openLink(uri);
    }
    return true;
  }

  Future<void> _openInBrowser(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    var opened = false;
    try {
      final dir = _browserCopyDir ??= await _createPrivateDir();
      final file = io.File(p.join(dir.path, 'email.html'));
      // The sanitiser strips `<meta charset>`, so the BOM is what tells the
      // browser this file is UTF-8.
      await file.writeAsString('﻿${body.html}', flush: true);
      opened = await openInBrowser(file.path);
    } on io.IOException catch (_) {
      // Covers a missing xdg-open as well as an unwritable temp directory.
    }
    if (!opened) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not open browser')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final plainText = body.plainText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (plainText == null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _openInBrowser(context),
              icon: const Icon(Icons.open_in_browser, size: 16),
              label: const Text('Open in browser'),
            ),
          ),
        Expanded(
          // Mail is written for a white page, whatever the app's theme is.
          child: ColoredBox(
            color: Colors.white,
            child: SelectionArea(
              child: SingleChildScrollView(
                // A new message starts at the top.
                key: ObjectKey(body),
                padding: const EdgeInsets.all(16),
                child:
                    plainText != null
                        ? Text(
                          plainText,
                          style: const TextStyle(color: Colors.black87),
                        )
                        : HtmlWidget(
                          body.html,
                          factoryBuilder: EmailHtmlWidgetFactory.new,
                          // The widget has no notion of `<head>`, so the
                          // subject would show up as body text.
                          customStylesBuilder:
                              (element) =>
                                  element.localName == 'title'
                                      ? const {'display': 'none'}
                                      : null,
                          onTapUrl: _handleLink,
                          textStyle: const TextStyle(color: Colors.black87),
                        ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
