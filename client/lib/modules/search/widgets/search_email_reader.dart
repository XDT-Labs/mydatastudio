import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/modules/email/widgets/email_details.dart';

/// Full-window reader for a mail hit — the spacebar's destination, matching
/// what the lightbox does for a photo.
///
/// The sidebar shows the message in a 200-500px box, which is enough to see why
/// something matched and not enough to actually read a long thread. This gives
/// the body the whole window, keeps the header identifying which message it is,
/// and steps through the other mail in the results with the arrow keys.
class SearchEmailReader extends StatefulWidget {
  const SearchEmailReader({
    super.key,
    required this.email,
    required this.onClose,
    this.onNext,
    this.onPrevious,
    this.position,
  });

  final Email email;
  final VoidCallback onClose;

  /// Null when this is the only mail in the loaded results.
  final VoidCallback? onNext;
  final VoidCallback? onPrevious;

  /// "3 of 41", when the page can say where in the results this sits.
  final String? position;

  @override
  State<SearchEmailReader> createState() => _SearchEmailReaderState();
}

class _SearchEmailReaderState extends State<SearchEmailReader> {
  final FocusNode _focusNode = FocusNode();

  static final DateFormat _dateFormat = DateFormat.yMMMd().add_jm();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final email = widget.email;
    final subject = email.subject?.trim();

    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.escape):
            const _CloseReaderIntent(),
        const SingleActivator(LogicalKeyboardKey.space):
            const _CloseReaderIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowRight):
            const _NextEmailIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft):
            const _PreviousEmailIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _CloseReaderIntent: CallbackAction<_CloseReaderIntent>(
            onInvoke: (_) {
              widget.onClose();
              return null;
            },
          ),
          _NextEmailIntent: CallbackAction<_NextEmailIntent>(
            onInvoke: (_) {
              widget.onNext?.call();
              return null;
            },
          ),
          _PreviousEmailIntent: CallbackAction<_PreviousEmailIntent>(
            onInvoke: (_) {
              widget.onPrevious?.call();
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: _focusNode,
          autofocus: true,
          child: Material(
            color: theme.colorScheme.surface,
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainer,
                      border: Border(
                        bottom: BorderSide(
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.4,
                          ),
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                subject == null || subject.isEmpty
                                    ? '(No subject)'
                                    : subject,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${email.from}  ·  ${_dateFormat.format(email.date)}'
                                '${widget.position == null ? '' : '  ·  ${widget.position}'}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        if (widget.onPrevious != null)
                          IconButton(
                            icon: const Icon(Icons.chevron_left),
                            tooltip: 'Previous',
                            onPressed: widget.onPrevious,
                          ),
                        if (widget.onNext != null)
                          IconButton(
                            icon: const Icon(Icons.chevron_right),
                            tooltip: 'Next',
                            onPressed: widget.onNext,
                          ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Close',
                          onPressed: widget.onClose,
                        ),
                      ],
                    ),
                  ),
                  Expanded(child: EmailDetails(email: email)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CloseReaderIntent extends Intent {
  const _CloseReaderIntent();
}

class _NextEmailIntent extends Intent {
  const _NextEmailIntent();
}

class _PreviousEmailIntent extends Intent {
  const _PreviousEmailIntent();
}
