import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/models/tables/file.dart' as model;
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/models/search_result.dart';
import 'package:mydatastudio/modules/search/services/retrievers/bm25_retriever.dart';
import 'package:mydatastudio/modules/search/services/search_detail_repository.dart';
import 'package:mydatastudio/modules/search/services/search_service.dart';
import 'package:mydatastudio/modules/search/widgets/search_email_reader.dart';
import 'package:mydatastudio/modules/search/widgets/search_email_sidebar.dart';
import 'package:mydatastudio/modules/search/services/suggestions/field_suggestion_service.dart';
import 'package:mydatastudio/modules/search/widgets/search_facet_bar.dart';
import 'package:mydatastudio/modules/search/widgets/search_field.dart';
import 'package:mydatastudio/modules/search/widgets/search_file_sidebar.dart';
import 'package:mydatastudio/modules/search/widgets/search_filter_chips.dart';
import 'package:mydatastudio/modules/search/widgets/search_lightbox.dart';
import 'package:mydatastudio/modules/search/widgets/search_result_tile.dart';
import 'package:mydatastudio/modules/search/widgets/summarize_results_dialog.dart';

/// Top-level search screen: a query box over a ranked, faceted result list,
/// with a detail panel beside it for whichever result is selected.
///
/// Renders four states that must stay visually distinct — "no query yet" is
/// a blank slate, not a failure, while "empty results" says a real query came
/// back with nothing. Conflating them reads as the app being broken every
/// time a user lands here fresh.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.initialQuery, this.detailLoader});

  final String initialQuery;

  /// Injection seam for widget tests, which have no database behind them.
  final SearchDetailRepository? detailLoader;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final TextEditingController _controller;
  final ScrollController _scrollController = ScrollController();

  /// Focus for the query box, and for the page body behind it.
  ///
  /// Selecting a row moves focus off the query box and onto [_bodyFocus], which
  /// is what makes the spacebar mean "open this result" instead of typing a
  /// space. Without the handoff the query box keeps focus after a click — a
  /// `TextField` swallows the key before any ancestor shortcut sees it.
  final FocusNode _searchFocus = FocusNode();
  final FocusNode _bodyFocus = FocusNode(debugLabel: 'search results');

  StreamSubscription<SearchResults>? _resultsSub;
  StreamSubscription<bool>? _loadingSub;

  SearchResults _results = SearchResults.empty;
  bool _isLoading = false;
  SearchFacet _facet = SearchFacet.all;

  /// Index into `_results.results` of the row whose detail panel is open, or
  /// null when nothing is selected and the list has the width to itself.
  int? _selectedIndex;

  /// The full records behind [_selectedIndex]. A `SearchResult` is a flattened
  /// row shared by mail and files; the panels need the real thing.
  model.File? _selectedFile;
  Email? _selectedEmail;
  Collection? _selectedCollection;
  bool _detailLoading = false;

  /// Bumped on every selection change so a slow load that lands after the user
  /// has moved on is discarded instead of overwriting the newer selection.
  int _detailToken = 0;

  /// The in-flight load for the current selection, so a double-click can wait
  /// on the same fetch the sidebar is already making instead of issuing another.
  Future<void>? _detailFuture;

  bool _isFullscreen = false;
  bool _panelWide = false;

  late final SearchDetailRepository _detailLoader;

  /// Backs the `field:` value dropdown. Null when there is no database — a
  /// widget test, or a launch where the archive has not opened yet — and the
  /// query box simply offers no completions rather than failing.
  FieldSuggestionService? _suggestions;

  static const _panelWidth = 320.0;
  static const _panelWideWidth = 640.0;

  /// Distance from the bottom at which the next page is requested. Far enough
  /// ahead that the fetch usually lands before the user reaches the end.
  static const _loadMoreThreshold = 600.0;

  /// The last query actually run (trimmed), distinct from what's currently
  /// typed. An empty value means "nothing has been searched yet" — the
  /// signal that separates the neutral prompt from a real zero-result search.
  String _lastRunQuery = '';

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery);
    _detailLoader = widget.detailLoader ?? const SearchDetailRepository();

    final database = DatabaseManager.instance.database;
    if (database != null) {
      _suggestions = FieldSuggestionService.forDatabase(database);
    }

    _scrollController.addListener(_onScroll);

    _resultsSub = SearchService.instance.sink.listen((results) {
      if (!mounted) return;
      setState(() {
        _results = results;
        _dropSelectionIfGone();
      });
    });
    _loadingSub = SearchService.instance.isLoading.listen((loading) {
      if (mounted) setState(() => _isLoading = loading);
    });

    final trimmedInitial = widget.initialQuery.trim();
    if (trimmedInitial.isNotEmpty) {
      _lastRunQuery = trimmedInitial;
      _runSearch(trimmedInitial);
    }
  }

  @override
  void dispose() {
    _resultsSub?.cancel();
    _loadingSub?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _controller.dispose();
    _searchFocus.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  /// Requests the next page as the list nears its end.
  ///
  /// The service guards against re-entry, which matters because this fires on
  /// every scroll frame — one flick past the threshold would otherwise queue a
  /// page per frame and append each of them.
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels < position.maxScrollExtent - _loadMoreThreshold) return;
    if (!SearchService.instance.hasMore) return;
    SearchService.instance.loadMore();
  }

  void _onFacetSelected(SearchFacet facet) {
    setState(() {
      _facet = facet;
      _clearSelectionState();
    });
    // Re-query rather than slice: the counts are archive totals, so choosing
    // a facet has to be able to reach every one of them.
    SearchService.instance.setSourceFilter(sourceTypeForFacet(facet));
  }

  void _runSearch(String rawQuery) {
    final database = DatabaseManager.instance.database;
    if (database == null) {
      // App startup races DB init; a query submitted before it's open has
      // nowhere to run yet. Nothing to do beyond staying put — the next
      // successful submit will pick it up.
      return;
    }
    // The selected facet rides along. Without it a new query ran unrestricted
    // while the chip stayed lit, so "Photos & Files" could sit highlighted
    // above a list of mail — the UI claiming a filter it was not applying.
    SearchService.instance.invoke(
      SearchCommand(
        rawQuery,
        database,
        sourceFilter: sourceTypeForFacet(_facet),
      ),
    );
  }

  void _onSubmitted(String value) {
    setState(() {
      _lastRunQuery = value.trim();
      _clearSelectionState();
    });
    _runSearch(value);
  }

  void _onRemoveFilter(QueryFilter filter) {
    final updated = _withFilterRemoved(_controller.text, filter);
    _controller.text = updated;
    _controller.selection = TextSelection.collapsed(offset: updated.length);
    setState(() {
      _lastRunQuery = updated.trim();
      _clearSelectionState();
    });
    _runSearch(updated);
  }

  /// Strips the token a [QueryFilter] would have parsed from, so removing a
  /// chip edits the query text the same way deleting it by hand would.
  ///
  /// A filter inferred from prose has no such token — `emails from mike nimer`
  /// yields `from:mnimer@allaire.com`, an address that appears nowhere in what
  /// was typed. Those carry the words they came from, and removing the chip
  /// deletes the phrase instead. Without this the delete matches nothing, the
  /// chip stays put, and the identical results come back — a button that looks
  /// broken rather than one that did nothing.
  String _withFilterRemoved(String raw, QueryFilter filter) {
    final token = filter.sourceText ?? _tokenFor(filter);
    return raw.replaceFirst(token, '').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _tokenFor(QueryFilter filter) {
    final fieldName = SearchFilterChips.fieldName(filter.field);
    final needsQuotes = filter.value.contains(' ');
    final value = needsQuotes ? '"${filter.value}"' : filter.value;
    final sign = filter.negated ? '-' : '';
    return '$sign$fieldName:$value';
  }

  // ─── Selection and detail loading ──────────────────────────────────────

  SearchResult? get _selectedResult {
    final index = _selectedIndex;
    if (index == null || index >= _results.results.length) return null;
    return _results.results[index];
  }

  /// Clears selection without touching the widget tree. Callers are already
  /// inside a `setState`.
  void _clearSelectionState() {
    _selectedIndex = null;
    _selectedFile = null;
    _selectedEmail = null;
    _selectedCollection = null;
    _detailLoading = false;
    _isFullscreen = false;
    _detailToken++;
  }

  /// Drops a selection whose row is no longer in the result list.
  ///
  /// Paging only appends, so an index normally stays pointed at the same row.
  /// A re-query replaces the list wholesale, though, and an index that survives
  /// that would leave the panel describing whatever now happens to sit at that
  /// position.
  void _dropSelectionIfGone() {
    final index = _selectedIndex;
    if (index == null) return;
    final selectedKey = _selectedFile?.id ?? _selectedEmail?.id;
    if (index >= _results.results.length) {
      _clearSelectionState();
      return;
    }
    if (selectedKey != null && _results.results[index].id != selectedKey) {
      _clearSelectionState();
    }
  }

  void _selectIndex(int index) {
    if (index < 0 || index >= _results.results.length) return;
    final token = ++_detailToken;
    setState(() {
      _selectedIndex = index;
      _selectedFile = null;
      _selectedEmail = null;
      _selectedCollection = null;
      _detailLoading = true;
    });
    // Hand focus to the body so the spacebar reaches the shortcut instead of
    // typing into the query box.
    _searchFocus.unfocus();
    _bodyFocus.requestFocus();
    _detailFuture = _loadDetail(_results.results[index], token);
  }

  Future<void> _loadDetail(SearchResult result, int token) async {
    Collection? collection;
    model.File? file;
    Email? email;
    try {
      if (result.isFile) {
        file = await _detailLoader.fileById(result.id);
      } else {
        email = await _detailLoader.emailById(result.id);
      }
      final collectionId = result.collectionId ?? file?.collectionId;
      if (collectionId != null) {
        collection = await _detailLoader.collectionById(collectionId);
      }
    } catch (_) {
      // A record deleted between indexing and now, or a database that closed
      // under us. The panel shows its "couldn't load" state rather than
      // taking the page down.
    }
    if (!mounted || token != _detailToken) return;
    setState(() {
      _selectedFile = file;
      _selectedEmail = email;
      _selectedCollection = collection;
      _detailLoading = false;
    });
  }

  /// Indices of every loaded result of the same kind as the current selection —
  /// what the lightbox and reader step through with the arrow keys.
  List<int> get _siblingIndices {
    final selected = _selectedResult;
    if (selected == null) return const [];
    final indices = <int>[];
    for (var i = 0; i < _results.results.length; i++) {
      if (_results.results[i].type == selected.type) indices.add(i);
    }
    return indices;
  }

  String? get _positionLabel {
    final index = _selectedIndex;
    if (index == null) return null;
    final siblings = _siblingIndices;
    final at = siblings.indexOf(index);
    if (at < 0 || siblings.length < 2) return null;
    return '${at + 1} of ${siblings.length}';
  }

  void _step(int delta) {
    final index = _selectedIndex;
    if (index == null) return;
    final siblings = _siblingIndices;
    final at = siblings.indexOf(index);
    if (at < 0) return;
    final next = at + delta;
    // Deliberately no wrap-around: the loaded list is a window onto a longer
    // ranked set, so wrapping from the last loaded row back to the first would
    // claim an end that isn't there.
    if (next < 0 || next >= siblings.length) return;
    _selectIndex(siblings[next]);
  }

  /// Opens the lightbox or the reader for the current selection.
  ///
  /// Does nothing while the record is still loading — a viewer with nothing in
  /// it is worse than a keypress that appears not to have registered.
  void _openFullscreen() {
    if (_selectedFile == null && _selectedEmail == null) return;
    setState(() => _isFullscreen = true);
  }

  void _closeFullscreen() => setState(() => _isFullscreen = false);

  void _onEscape() {
    if (_isFullscreen) {
      _closeFullscreen();
      return;
    }
    if (_selectedIndex != null) setState(_clearSelectionState);
  }

  // ─── Build ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.space): _OpenSelectedIntent(),
        SingleActivator(LogicalKeyboardKey.escape): _DismissIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _OpenSelectedIntent: CallbackAction<_OpenSelectedIntent>(
            onInvoke: (_) {
              // Belt and braces: a TextField normally consumes the key before
              // this ever runs, but a stray focus state must not turn a typed
              // space into a fullscreen viewer.
              if (_searchFocus.hasFocus) return null;
              _openFullscreen();
              return null;
            },
          ),
          _DismissIntent: CallbackAction<_DismissIntent>(
            onInvoke: (_) {
              _onEscape();
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: _bodyFocus,
          child: Stack(
            children: [
              Scaffold(
                body: SafeArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                        child: SearchField(
                          controller: _controller,
                          focusNode: _searchFocus,
                          onSubmitted: _onSubmitted,
                          suggestions: _suggestions,
                        ),
                      ),
                      if (_isLoading)
                        const LinearProgressIndicator(minHeight: 2),
                      Expanded(child: _buildBody(context)),
                    ],
                  ),
                ),
              ),
              if (_isFullscreen) Positioned.fill(child: _buildFullscreen()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFullscreen() {
    final siblings = _siblingIndices;
    final at = siblings.indexOf(_selectedIndex ?? -1);
    final onPrevious = at > 0 ? () => _step(-1) : null;
    final onNext = at >= 0 && at < siblings.length - 1 ? () => _step(1) : null;

    final email = _selectedEmail;
    if (email != null) {
      return SearchEmailReader(
        email: email,
        onClose: _closeFullscreen,
        onNext: onNext,
        onPrevious: onPrevious,
        position: _positionLabel,
      );
    }

    final file = _selectedFile;
    final collection = _selectedCollection;
    if (file == null || collection == null) return const SizedBox.shrink();

    return SearchLightbox(
      file: file,
      collection: collection,
      onClose: _closeFullscreen,
      onNext: onNext,
      onPrevious: onPrevious,
      position: _positionLabel,
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_lastRunQuery.isEmpty) {
      return const _NoQueryYetView();
    }
    // Still waiting on the first response for this query — nothing to call
    // "empty" yet, so this is loading, not a real zero-result state.
    if (_results.isEmpty && _isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    // Everything else keeps the chrome. An empty facet used to replace the
    // whole page, taking the filter chips and facet bar with it — selecting
    // "Emails 0" left no control to get back to "All", which is a dead end
    // reachable in one click.
    return _buildResults(context);
  }

  /// Opens the summarize dialog for the set currently on screen.
  ///
  /// The semantic-only counts travel with it because they are what decides
  /// whether the answer may say "all": they are the results no keyword
  /// matched, which came from a top-K vector scan the summarizer's paging can
  /// never reproduce.
  void _summarizeResults(ParsedQuery query) {
    showDialog<void>(
      context: context,
      builder:
          (_) => SummarizeResultsDialog(
            query: query,
            semanticOnly:
                _results.emailSemanticOnly + _results.fileSemanticOnly,
            retrieved: SearchService.instance.retrieved,
          ),
    );
  }

  Widget _buildResults(BuildContext context) {
    final lastQuery = SearchService.instance.lastQuery;
    // The service already restricted retrieval to the selected facet, so what
    // arrived is what belongs on screen.
    final filtered = _results.results;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (lastQuery != null && lastQuery.hasFilters)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: SearchFilterChips(
              filters: lastQuery.filters,
              onRemove: _onRemoveFilter,
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Row(
            children: [
              Expanded(
                child: SearchFacetBar(
                  total: _results.total,
                  emailTotal: _results.emailTotal,
                  fileTotal: _results.fileTotal,
                  selected: _facet,
                  onSelected: _onFacetSelected,
                ),
              ),
              // Explicit, never automatic. Summarizing is minutes of local
              // inference over the whole set, and the user has to have
              // finished choosing that set before it is worth spending.
              if (lastQuery != null && _results.total > 0)
                TextButton.icon(
                  onPressed: () => _summarizeResults(lastQuery),
                  icon: const Icon(Icons.auto_awesome, size: 16),
                  label: const Text('Summarize these results'),
                ),
            ],
          ),
        ),
        // No "showing the first N of M" line: the facet counts already state
        // the real totals, and the list reaches all of them as it scrolls.
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child:
                    filtered.isEmpty
                        ? _EmptyResultsView(
                          query: _lastRunQuery,
                          hasFilters: lastQuery?.hasFilters ?? false,
                          // A facet with nothing in it, while other facets do
                          // have matches, is a different situation from a query
                          // that found nothing anywhere — and the way out
                          // differs too.
                          otherFacetsHaveResults:
                              _facet != SearchFacet.all && _results.total > 0,
                        )
                        : _buildList(filtered),
              ),
              _buildDetailsPanel(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildList(List<SearchResult> filtered) {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.only(bottom: 16),
      // One extra row for the paging footer.
      itemCount: filtered.length + 1,
      itemBuilder: (context, index) {
        if (index == filtered.length) {
          return _PagingFooter(
            hasMore: SearchService.instance.hasMore,
            loadedCount: filtered.length,
            total: _results.total,
          );
        }
        return SearchResultTile(
          result: filtered[index],
          isSelected: _selectedIndex == index,
          onTap: () => _selectIndex(index),
          onDoubleTap: () => _openAt(index),
          onExpand: () => _openAt(index),
          onOpenParentEmail: _openParentEmail,
        );
      },
    );
  }

  /// Selects [index] and opens its viewer once the record has loaded.
  ///
  /// Double-clicking an unselected row has to wait for the same load the
  /// sidebar is already making — opening a viewer against a half-loaded
  /// selection would show the previous result's contents. The token re-check
  /// after the await is what makes a third click during the wait win.
  /// Opens the message an attachment arrived with.
  ///
  /// Deliberately independent of the result list. The parent email usually did
  /// *not* match the query — the attachment did — so there is no index to
  /// select, and the reader is driven straight from the loaded record instead.
  /// Clearing [_selectedIndex] is what makes that safe: both [_positionLabel]
  /// and [_siblingIndices] key off it, so the reader correctly offers no
  /// next/previous rather than stepping through results the message is not
  /// part of.
  Future<void> _openParentEmail(String emailId) async {
    final token = ++_detailToken;
    Email? email;
    try {
      email = await _detailLoader.emailById(emailId);
    } catch (_) {
      // Same posture as _loadDetail: a message deleted since indexing should
      // not take the page down.
    }
    if (!mounted || token != _detailToken || email == null) return;
    setState(() {
      _selectedIndex = null;
      _selectedFile = null;
      _selectedEmail = email;
      _selectedCollection = null;
      _detailLoading = false;
    });
    _openFullscreen();
  }

  Future<void> _openAt(int index) async {
    if (_selectedIndex != index) {
      _selectIndex(index);
      final token = _detailToken;
      await _detailFuture;
      if (!mounted || token != _detailToken) return;
    }
    _openFullscreen();
  }

  /// The detail panel beside the list.
  ///
  /// Inline rather than an overlay, matching the Files module: it takes width
  /// from the list instead of covering it, so the ranked order behind it stays
  /// readable while a result is being inspected — which is the whole point when
  /// what is being judged is the ranking itself.
  Widget _buildDetailsPanel() {
    final theme = Theme.of(context);
    final isVisible = _selectedIndex != null;
    final width = _panelWide ? _panelWideWidth : _panelWidth;

    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      alignment: Alignment.topRight,
      child:
          !isVisible
              ? const SizedBox.shrink()
              : Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: SizedBox(
                  width: width,
                  child: Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant.withValues(
                          alpha: 0.2,
                        ),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: _buildPanelContents(width),
                  ),
                ),
              ),
    );
  }

  Widget _buildPanelContents(double width) {
    if (_detailLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final email = _selectedEmail;
    if (email != null) {
      return SearchEmailSidebar(
        email: email,
        collection: _selectedCollection,
        width: width,
        isWide: _panelWide,
        onToggleWidth: () => setState(() => _panelWide = !_panelWide),
        onClose: () => setState(_clearSelectionState),
        onOpenReader: _openFullscreen,
      );
    }

    final file = _selectedFile;
    final collection = _selectedCollection;
    if (file != null && collection != null) {
      return SearchFileSidebar(
        file: file,
        collection: collection,
        width: width,
        isWide: _panelWide,
        onToggleWidth: () => setState(() => _panelWide = !_panelWide),
        onClose: () => setState(_clearSelectionState),
        onOpenLightbox: _openFullscreen,
      );
    }

    return _PanelUnavailable(
      // A file with no collection is the case worth naming: the row is in the
      // index but the account it came from is gone, so nothing can resolve its
      // path. Saying "not found" would send someone looking for a bug in the
      // panel instead of at the collection.
      message:
          file != null
              ? 'This file\'s collection is no longer available.'
              : 'This result could not be loaded.',
      onClose: () => setState(_clearSelectionState),
    );
  }
}

class _OpenSelectedIntent extends Intent {
  const _OpenSelectedIntent();
}

class _DismissIntent extends Intent {
  const _DismissIntent();
}

class _PanelUnavailable extends StatelessWidget {
  const _PanelUnavailable({required this.message, required this.onClose});

  final String message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Close',
            onPressed: onClose,
          ),
        ),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _NoQueryYetView extends StatelessWidget {
  const _NoQueryYetView();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search,
            size: 64,
            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'Search your files, emails, and photos',
            style: theme.textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Try "from:mom vacation" or "invoices after:2025"',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyResultsView extends StatelessWidget {
  const _EmptyResultsView({
    required this.query,
    required this.hasFilters,
    this.otherFacetsHaveResults = false,
  });

  final String query;
  final bool hasFilters;

  /// True when this facet is empty but the query matched elsewhere. Says so
  /// explicitly rather than claiming the query found nothing — the facet bar
  /// above is still showing non-zero counts, and a message contradicting it
  /// reads as a bug.
  final bool otherFacetsHaveResults;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.search_off,
              size: 64,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              otherFacetsHaveResults
                  ? 'Nothing here for "$query"'
                  : 'No results for "$query"',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              otherFacetsHaveResults
                  ? 'Other categories above still have matches.'
                  : hasFilters
                  ? 'Your filters may be narrowing the results.'
                  : '',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The row below the last result: a spinner while the next page loads, or a
/// quiet end-of-list marker once everything has been fetched.
///
/// The end marker states the count so a long scroll ends with confirmation
/// that the list really is complete, rather than just stopping.
class _PagingFooter extends StatelessWidget {
  const _PagingFooter({
    required this.hasMore,
    required this.loadedCount,
    required this.total,
  });

  final bool hasMore;
  final int loadedCount;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (hasMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    // Nothing to say when everything fits on one page — the list speaks for
    // itself and a footer would just be furniture.
    if (loadedCount >= total && total <= Bm25Retriever.pageSize) {
      return const SizedBox(height: 8);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Text(
          'All $total results',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
