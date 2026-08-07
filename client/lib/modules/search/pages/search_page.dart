import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/models/search_result.dart';
import 'package:mydatastudio/modules/search/services/retrievers/bm25_retriever.dart';
import 'package:mydatastudio/modules/search/services/search_service.dart';
import 'package:mydatastudio/modules/search/widgets/search_facet_bar.dart';
import 'package:mydatastudio/modules/search/widgets/search_filter_chips.dart';
import 'package:mydatastudio/modules/search/widgets/search_result_tile.dart';

/// Top-level search screen: a query box over a ranked, faceted result list.
///
/// Renders four states that must stay visually distinct — "no query yet" is
/// a blank slate, not a failure, while "empty results" says a real query came
/// back with nothing. Conflating them reads as the app being broken every
/// time a user lands here fresh.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.initialQuery});

  final String initialQuery;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final TextEditingController _controller;
  final ScrollController _scrollController = ScrollController();
  StreamSubscription<SearchResults>? _resultsSub;
  StreamSubscription<bool>? _loadingSub;

  SearchResults _results = SearchResults.empty;
  bool _isLoading = false;
  SearchFacet _facet = SearchFacet.all;

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

    _scrollController.addListener(_onScroll);

    _resultsSub = SearchService.instance.sink.listen((results) {
      if (!mounted) return;
      setState(() => _results = results);
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
    setState(() => _facet = facet);
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
    setState(() => _lastRunQuery = value.trim());
    _runSearch(value);
  }

  void _onRemoveFilter(QueryFilter filter) {
    final updated = _withFilterRemoved(_controller.text, filter);
    _controller.text = updated;
    _controller.selection = TextSelection.collapsed(offset: updated.length);
    setState(() => _lastRunQuery = updated.trim());
    _runSearch(updated);
  }

  /// Strips the token a [QueryFilter] would have parsed from, so removing a
  /// chip edits the query text the same way deleting it by hand would.
  String _withFilterRemoved(String raw, QueryFilter filter) {
    final fieldName = SearchFilterChips.fieldName(filter.field);
    final needsQuotes = filter.value.contains(' ');
    final value = needsQuotes ? '"${filter.value}"' : filter.value;
    final sign = filter.negated ? '-' : '';
    final token = '$sign$fieldName:$value';
    return raw.replaceFirst(token, '').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
              child: _SearchBar(
                controller: _controller,
                onSubmitted: _onSubmitted,
                colorScheme: colorScheme,
              ),
            ),
            if (_isLoading) const LinearProgressIndicator(minHeight: 2),
            Expanded(child: _buildBody(context)),
          ],
        ),
      ),
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

  Widget _buildResults(BuildContext context) {
    final theme = Theme.of(context);
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
          child: SearchFacetBar(
            total: _results.total,
            emailTotal: _results.emailTotal,
            fileTotal: _results.fileTotal,
            selected: _facet,
            onSelected: _onFacetSelected,
          ),
        ),
        // No "showing the first N of M" line: the facet counts already state
        // the real totals, and the list reaches all of them as it scrolls.
        Expanded(
          child:
              filtered.isEmpty
                  ? _EmptyResultsView(
                    query: _lastRunQuery,
                    hasFilters: lastQuery?.hasFilters ?? false,
                    // A facet with nothing in it, while other facets do have
                    // matches, is a different situation from a query that
                    // found nothing anywhere — and the way out differs too.
                    otherFacetsHaveResults:
                        _facet != SearchFacet.all && _results.total > 0,
                  )
                  : ListView.separated(
                    controller: _scrollController,
                    padding: const EdgeInsets.only(bottom: 16),
                    // One extra row for the paging footer.
                    itemCount: filtered.length + 1,
                    separatorBuilder:
                        (_, _) => Divider(
                          height: 1,
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.3,
                          ),
                        ),
                    itemBuilder: (context, index) {
                      if (index == filtered.length) {
                        return _PagingFooter(
                          hasMore: SearchService.instance.hasMore,
                          loadedCount: filtered.length,
                          total: _results.total,
                        );
                      }
                      return SearchResultTile(result: filtered[index]);
                    },
                  ),
        ),
      ],
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.onSubmitted,
    required this.colorScheme,
  });

  final TextEditingController controller;
  final ValueChanged<String> onSubmitted;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
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
