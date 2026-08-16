import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/aichat/pages/aichat_page.dart';
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/models/search_result.dart';
import 'package:mydatastudio/modules/search/services/result_set_summarizer.dart';
import 'package:mydatastudio/repositories/aichat_repository.dart';

/// Runs [ResultSetSummarizer] over the current result set and shows the answer.
///
/// It is a dialog rather than something the results list grows into, because
/// summarizing is a minutes-long operation over a set the user has finished
/// choosing — mixing it into the list would put a progress bar in the middle
/// of a page whose whole job is to stay responsive while typing.
class SummarizeResultsDialog extends StatefulWidget {
  const SummarizeResultsDialog({
    super.key,
    required this.query,
    this.semanticOnly = 0,
    this.retrieved = const [],
    this.run,
    this.handoff,
  });

  final ParsedQuery query;

  /// On-screen results that only a vector matched — see
  /// [ResultSetSummarizer.summarize].
  final int semanticOnly;

  /// Everything the search itself retrieved — `SearchService.retrieved`.
  ///
  /// The button says "summarize these results", and this is what "these"
  /// means. Re-deriving the set from the lexical retriever gives a different,
  /// smaller one whenever free text is involved.
  final List<SearchResult> retrieved;

  /// Injection seams for widget tests, which have neither a database nor a
  /// model behind them.
  final SummarizeRunner? run;
  final Future<String> Function(ParsedQuery, ResultSetSummary)? handoff;

  @override
  State<SummarizeResultsDialog> createState() => _SummarizeResultsDialogState();
}

class _SummarizeResultsDialogState extends State<SummarizeResultsDialog> {
  SummarizeProgress? _progress;
  ResultSetSummary? _summary;
  bool _failed = false;
  SummarizeFailure? _reason;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final db = DatabaseManager.instance.database;
    final summarizer = db == null ? null : ResultSetSummarizer(db: db);
    final run = widget.run ?? summarizer?.summarize;
    if (run == null) {
      setState(() => _failed = true);
      return;
    }

    final summary = await run(
      widget.query,
      semanticOnly: widget.semanticOnly,
      retrieved: widget.retrieved,
      // Guarded because the run outlives the dialog if it is dismissed early.
      onProgress: (p) => mounted ? setState(() => _progress = p) : null,
    );
    if (!mounted) return;
    setState(() {
      _summary = summary;
      _failed = summary == null;
      _reason = summarizer?.lastFailure;
    });
  }

  /// What to tell the user when nothing came back.
  ///
  /// The first version said "the AI service may not be running" for every
  /// failure. The first real one in the wild was a batch timeout against a
  /// service that was running perfectly, and the message sent the reader off
  /// to check the model. A wrong diagnosis costs more than no diagnosis.
  String get _failureMessage => switch (_reason) {
    SummarizeFailure.noResults =>
      'There is nothing to summarize for this search.',
    SummarizeFailure.timedOut =>
      'The model did not finish a batch in time. It may be busy with '
          'background indexing — try again, or narrow the search.',
    SummarizeFailure.modelError =>
      'The AI service rejected the request. Check that a chat model is '
          'selected and loaded.',
    SummarizeFailure.serviceUnavailable =>
      'Could not reach the AI service.',
    null => 'Could not summarize these results.',
  };

  /// Writes the summary into a new conversation, then opens it.
  ///
  /// The conversation is created and selected *before* navigating, and the
  /// selection goes through `AichatPage.selectConversationId` — the same
  /// notifier the chat drawer uses to switch conversations. Passing the text
  /// through the route instead depended on three things that each failed
  /// quietly: that the route rebuilt the page's State so `initState` re-ran,
  /// that `extra` survived the navigation, and that the router was still
  /// reachable through a context popped a line earlier. What landed was the
  /// previous conversation with none of the summary in it.
  Future<void> _continueInChat() async {
    final summary = _summary;
    if (summary == null) return;
    final db = DatabaseManager.instance.database;
    // The database is only needed by the real handoff; an injected one brings
    // its own storage.
    final handoff =
        widget.handoff ??
        (db == null ? null : SummaryChatHandoff(AichatRepository(db)).create);
    if (handoff == null) return;

    final router = GoRouter.of(context);
    final navigator = Navigator.of(context);
    final id = await handoff(widget.query, summary);

    AichatPage.selectConversationId.value = id;
    navigator.pop();
    router.go('/aichat');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = _summary;

    return AlertDialog(
      title: const Text('Summary'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child:
              summary != null
                  ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Above the summary, not below it. A reader who stops
                      // after the first paragraph has still been told what
                      // this covers.
                      Text(
                        summary.coverageStatement,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 12),
                      SelectableText(summary.text),
                    ],
                  )
                  : _failed
                  ? Text(_failureMessage)
                  : _ProgressView(progress: _progress),
        ),
      ),
      actions: [
        if (summary != null)
          TextButton(
            onPressed: _continueInChat,
            child: const Text('Continue in chat'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(summary == null && !_failed ? 'Cancel' : 'Close'),
        ),
      ],
    );
  }
}

class _ProgressView extends StatelessWidget {
  const _ProgressView({required this.progress});

  final SummarizeProgress? progress;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const LinearProgressIndicator(),
        const SizedBox(height: 16),
        // Naming the batch matters more than a percentage here: each one is a
        // slow local inference call, and "Condensing batch 3 of 9" is the only
        // thing distinguishing steady progress from a wedged subprocess.
        Text(p?.stage ?? 'Reading results'),
        if (p != null && p.itemsTotal > 0) ...[
          const SizedBox(height: 4),
          Text(
            '${p.itemsRead} of ${p.itemsTotal} results',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}
