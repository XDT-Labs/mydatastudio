import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/models/search_result.dart';
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
  StreamSubscription<SearchResults>? _resultsSub;
  StreamSubscription<bool>? _loadingSub;

  SearchResults _results = SearchResults.empty;
  bool _isLoading = false;
  SearchFacet _facet = SearchFacet.all;

  /// The last query actually run (trimmed), distinct from what's currently
  /// typed. An empty value means "nothing has been searched yet" — the
  /// signal that separates the neutral prompt from a real zero-result search.
  String _lastRunQuery = '';

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery);

    _resultsSub = SearchService.instance.sink.listen((results) {
      if (!mounted) return;
      setState(() {
        _results = results;
        // A fresh result set invalidates whatever slice was picked for the
        // previous one — staying on "Emails" after a query with zero emails
        // would silently show an empty list under a non-empty facet bar.
        _facet = SearchFacet.all;
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
    _controller.dispose();
    super.dispose();
  }

  void _runSearch(String rawQuery) {
    final database = DatabaseManager.instance.database;
    if (database == null) {
      // App startup races DB init; a query submitted before it's open has
      // nowhere to run yet. Nothing to do beyond staying put — the next
      // successful submit will pick it up.
      return;
    }
    SearchService.instance.invoke(SearchCommand(rawQuery, database));
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
    if (_results.isEmpty) {
      // Still waiting on the first response for this query — nothing to
      // call "empty" yet, so this is loading, not a real zero-result state.
      if (_isLoading) {
        return const Center(child: CircularProgressIndicator());
      }
      final lastQuery = SearchService.instance.lastQuery;
      return _EmptyResultsView(
        query: _lastRunQuery,
        hasFilters: lastQuery?.hasFilters ?? false,
      );
    }
    return _buildResults(context);
  }

  Widget _buildResults(BuildContext context) {
    final theme = Theme.of(context);
    final lastQuery = SearchService.instance.lastQuery;
    final filtered = filterResultsByFacet(_results.results, _facet);

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
            emailCount: _results.emailCount,
            fileCount: _results.fileCount,
            selected: _facet,
            onSelected: (facet) => setState(() => _facet = facet),
          ),
        ),
        if (_results.truncated)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              'Showing the first ${_results.results.length} '
              'of ${_results.grandTotal} matches',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.tertiary,
              ),
            ),
          ),
        Expanded(
          child:
              filtered.isEmpty
                  ? Center(
                    child: Text(
                      'No results in this category',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                  : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 16),
                    itemCount: filtered.length,
                    separatorBuilder:
                        (_, _) => Divider(
                          height: 1,
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.3,
                          ),
                        ),
                    itemBuilder:
                        (context, index) =>
                            SearchResultTile(result: filtered[index]),
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
  const _EmptyResultsView({required this.query, required this.hasFilters});

  final String query;
  final bool hasFilters;

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
              'No results for "$query"',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            if (hasFilters) ...[
              const SizedBox(height: 8),
              Text(
                'Your filters may be narrowing the results.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
