import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:mydatastudio/modules/search/services/query_tokenizer.dart';
import 'package:mydatastudio/modules/search/services/suggestions/field_suggestion.dart';
import 'package:mydatastudio/modules/search/services/suggestions/field_suggestion_service.dart';

class _HighlightNextIntent extends Intent {
  const _HighlightNextIntent();
}

class _HighlightPreviousIntent extends Intent {
  const _HighlightPreviousIntent();
}

class _AcceptSuggestionIntent extends Intent {
  const _AcceptSuggestionIntent();
}

class _CloseSuggestionsIntent extends Intent {
  const _CloseSuggestionsIntent();
}

/// Builds the text field itself. [onSubmitted] is the *wrapped* callback and
/// must be the one handed to the `TextField`, since that is where Enter is
/// routed to the highlighted suggestion instead of to the search.
typedef SearchFieldBuilder =
    Widget Function(
      BuildContext context,
      TextEditingController controller,
      FocusNode focusNode,
      ValueChanged<String> onSubmitted,
    );

/// Adds `field:` value completion to a caller-supplied text field.
///
/// Split from the field's appearance because the same behavior serves two
/// boxes that look nothing alike — the search page's full-width pill and the
/// app header's compact 36px input, which lives inside its own bordered
/// container with its own icon. Baking the decoration in would have meant
/// either duplicating the completion logic or giving the header the wrong
/// chrome.
///
/// Completion exists to remove ambiguity at the source rather than for
/// convenience: picking `mike@xdtlabs.com` from the list produces the exact
/// filter, so there is no name left to resolve and nothing to guess wrong. It
/// never *gates* anything — an address the archive has not seen stays typeable,
/// because mail gets deleted and not everything is synced yet.
class SearchFieldCompletion extends StatefulWidget {
  const SearchFieldCompletion({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSubmitted,
    required this.fieldBuilder,
    this.suggestions,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onSubmitted;
  final SearchFieldBuilder fieldBuilder;

  /// Null disables completion entirely — which is what a build with no
  /// database does, and what keeps this widget testable without one.
  final FieldSuggestionService? suggestions;

  @override
  State<SearchFieldCompletion> createState() => _SearchFieldCompletionState();
}

class _SearchFieldCompletionState extends State<SearchFieldCompletion> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _overlay;
  Timer? _debounce;

  List<FieldSuggestion> _options = const [];
  int _highlighted = 0;

  /// The token being completed, captured when the options were built. Accepting
  /// a suggestion rewrites exactly this span.
  QueryToken? _token;

  /// Guards against a slow load landing after the user has typed on. Without
  /// it, the list can repopulate with matches for a prefix that is no longer
  /// in the box.
  int _requestId = 0;

  /// Rebuild throttle, not database protection — §13e keeps the whole
  /// suggestion corpus in memory, so this only stops the list flickering
  /// through intermediate states while someone types quickly.
  static const _debounceDelay = Duration(milliseconds: 120);

  static const _maxOptions = 8;

  static const _minOverlayWidth = 320.0;

  bool get _isOpen => _overlay != null;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onEdited);
    widget.focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.controller.removeListener(_onEdited);
    widget.focusNode.removeListener(_onFocusChanged);
    _removeOverlay();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!widget.focusNode.hasFocus) _close();
  }

  void _onEdited() {
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, _refresh);
  }

  Future<void> _refresh() async {
    final service = widget.suggestions;
    if (service == null || !mounted || !widget.focusNode.hasFocus) {
      _close();
      return;
    }

    final selection = widget.controller.selection;
    final text = widget.controller.text;
    // A non-collapsed or absent selection means the user is selecting rather
    // than typing; there is no single caret to complete at.
    if (!selection.isValid || !selection.isCollapsed) {
      _close();
      return;
    }

    final token = QueryTokenizer.fieldTokenAt(text, selection.baseOffset);
    if (token == null || !service.supports(token.field!)) {
      _close();
      return;
    }

    final request = ++_requestId;
    final options = await service.suggest(
      token.field!,
      token.text,
      limit: _maxOptions,
    );
    if (!mounted || request != _requestId) return;

    if (options.isEmpty) {
      _close();
      return;
    }

    setState(() {
      _options = options;
      _token = token;
      _highlighted = 0;
    });
    _showOverlay();
    _overlay?.markNeedsBuild();
  }

  void _close() {
    if (!_isOpen && _options.isEmpty) return;
    _removeOverlay();
    if (mounted) {
      setState(() {
        _options = const [];
        _token = null;
      });
    } else {
      _options = const [];
      _token = null;
    }
  }

  void _showOverlay() {
    if (_overlay != null) return;
    final overlayState = Overlay.maybeOf(context);
    if (overlayState == null) return;
    _overlay = OverlayEntry(builder: _buildOverlay);
    overlayState.insert(_overlay!);
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  void _move(int delta) {
    if (!_isOpen) return;
    // No wrap-around: the list is short and always fully visible, so wrapping
    // would move the highlight somewhere the eye is not.
    final next = _highlighted + delta;
    if (next < 0 || next >= _options.length) return;
    setState(() => _highlighted = next);
    _overlay?.markNeedsBuild();
  }

  void _accept(int index) {
    final token = _token;
    if (token == null || index < 0 || index >= _options.length) return;

    final result = QueryTokenizer.applySuggestion(
      widget.controller.text,
      token,
      _options[index].value,
    );

    // Cancel the pending refresh first: setting .value fires the controller
    // listener, and letting that reopen the list right after a selection is
    // what makes an accepted suggestion look like it did not take.
    _debounce?.cancel();
    _requestId++;
    widget.controller.value = TextEditingValue(
      text: result.text,
      selection: TextSelection.collapsed(offset: result.caret),
    );
    _close();
  }

  /// Enter means "take the highlighted suggestion" while the list is open, and
  /// "run the search" only when it is closed.
  ///
  /// This is the classic autocomplete bug and it is worth the explicit
  /// handling: getting it backwards fires a search on every completion, using
  /// the half-typed value the user was in the middle of replacing.
  void _onSubmitted(String value) {
    if (_isOpen) {
      _accept(_highlighted);
      return;
    }
    widget.onSubmitted(value);
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: Shortcuts(
        // Bound here rather than at the page level so these win over Flutter's
        // DefaultTextEditingShortcuts, which sit near the root and would
        // otherwise move the caret instead of the highlight.
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.arrowDown): _HighlightNextIntent(),
          SingleActivator(LogicalKeyboardKey.arrowUp):
              _HighlightPreviousIntent(),
          SingleActivator(LogicalKeyboardKey.tab): _AcceptSuggestionIntent(),
          SingleActivator(LogicalKeyboardKey.escape): _CloseSuggestionsIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _HighlightNextIntent: CallbackAction<_HighlightNextIntent>(
              onInvoke: (_) {
                _move(1);
                return null;
              },
            ),
            _HighlightPreviousIntent: CallbackAction<_HighlightPreviousIntent>(
              onInvoke: (_) {
                _move(-1);
                return null;
              },
            ),
            _AcceptSuggestionIntent: CallbackAction<_AcceptSuggestionIntent>(
              onInvoke: (_) {
                if (_isOpen) _accept(_highlighted);
                return null;
              },
            ),
            _CloseSuggestionsIntent: CallbackAction<_CloseSuggestionsIntent>(
              onInvoke: (_) {
                // Only swallowed while the list is open; otherwise Escape
                // still belongs to the page, where it clears the selection.
                if (_isOpen) {
                  _close();
                } else {
                  Actions.invoke(context, const DismissIntent());
                }
                return null;
              },
            ),
          },
          child: widget.fieldBuilder(
            context,
            widget.controller,
            widget.focusNode,
            _onSubmitted,
          ),
        ),
      ),
    );
  }

  Widget _buildOverlay(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final box = this.context.findRenderObject() as RenderBox?;
    // Floored rather than simply matching the field: the header's box is only
    // ~240px wide, and a contact row is a name, an address and a count. Any
    // narrower and every row ellipsises into uselessness.
    final width = math.max(
      box?.size.width ?? _minOverlayWidth,
      _minOverlayWidth,
    );

    return Positioned(
      width: width,
      child: CompositedTransformFollower(
        link: _link,
        targetAnchor: Alignment.bottomLeft,
        followerAnchor: Alignment.topLeft,
        offset: const Offset(0, 4),
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          color: colorScheme.surfaceContainerHigh,
          child: ListView.builder(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            itemCount: _options.length,
            itemBuilder: (context, index) {
              final option = _options[index];
              final selected = index == _highlighted;
              return InkWell(
                onTap: () => _accept(index),
                child: Container(
                  color:
                      selected
                          ? colorScheme.primary.withValues(alpha: 0.12)
                          : null,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                option.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                            if (option.detail != null) ...[
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  option.detail!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      // The count is what lets two same-named contacts, or two
                      // near-duplicate tags (`mountain` vs `mountains`), be
                      // told apart at a glance.
                      if (option.count > 0) ...[
                        const SizedBox(width: 12),
                        Text(
                          '${option.count}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The search page's query box: a full-width pill, autofocused on arrival.
class SearchField extends StatelessWidget {
  const SearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSubmitted,
    this.suggestions,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onSubmitted;
  final FieldSuggestionService? suggestions;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return SearchFieldCompletion(
      controller: controller,
      focusNode: focusNode,
      onSubmitted: onSubmitted,
      suggestions: suggestions,
      fieldBuilder:
          (context, controller, focusNode, onSubmitted) => TextField(
            controller: controller,
            focusNode: focusNode,
            autofocus: true,
            onSubmitted: onSubmitted,
            textInputAction: TextInputAction.search,
            style: Theme.of(context).textTheme.bodyMedium,
            decoration: InputDecoration(
              hintText: 'Search files, emails, and more…',
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: colorScheme.surfaceContainerHigh,
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(999),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(999),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(999),
                borderSide: BorderSide(color: colorScheme.primary, width: 2),
              ),
            ),
          ),
    );
  }
}
