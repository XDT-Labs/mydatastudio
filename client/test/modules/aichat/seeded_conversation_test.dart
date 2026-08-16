import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/aichat/pages/aichat_page.dart';
import 'package:mydatastudio/modules/search/services/query_parser.dart';
import 'package:mydatastudio/modules/search/services/result_set_summarizer.dart';
import 'package:mydatastudio/repositories/aichat_repository.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Reopening a conversation the search handoff wrote.
///
/// The two halves of the handoff are tested elsewhere: that the summarizer
/// produces the summary, and that the handoff persists it. This is the seam
/// between them and the chat page — the point where a stored conversation
/// becomes two different things at once, a transcript for the reader and a
/// history for the model. Nothing else in the app makes that distinction, so
/// nothing else would catch it collapsing back into one list.
///
/// It goes through a real database and the real handoff rather than a fixture
/// of messages, because the bug this guards against is a mismatch between what
/// one side writes and what the other side expects of it.
final _createdDbs = <String>[];

Future<AppDatabase> _freshDb(String dbName) async {
  final supportDir = await getApplicationSupportDirectory();
  final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
  if (dbFile.existsSync()) dbFile.deleteSync();
  _createdDbs.add(dbFile.path);
  return AppDatabase.create(null, supportDir.path, dbName);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async => '.');
  });

  tearDownAll(() {
    for (final path in _createdDbs) {
      for (final suffix in const ['', '-wal', '-shm']) {
        final file = io.File('$path$suffix');
        if (file.existsSync()) file.deleteSync();
      }
    }
    _createdDbs.clear();
  });

  test('a seeded summary reopens as a two-turn exchange', () async {
    // Three messages were written; two are turns. The third is source
    // material — up to 60,000 characters of it — and it exists so the model
    // can answer "what was the technical question, and what was the answer",
    // which is precisely what a summary threw away. Rendering it would bury
    // the summary the user came back for under the raw archive.
    final db = await _freshDb('aichat_seeded_conversation_test.db');
    final id = await SummaryChatHandoff(AichatRepository(db)).create(
      QueryParser.parse('russell jong'),
      const ResultSetSummary(
        text: 'They discussed the contract.',
        coverage: SummaryCoverage.complete,
        itemsSummarized: 18,
        matchTotal: 18,
        batches: 1,
        sources: ['[1] Russell asked whether the token refresh was retried.'],
      ),
    );

    final (:transcript, :history) = splitConversation(
      await AichatRepository(db).getMessages(id),
    );

    expect(transcript.map((t) => t.role), ['user', 'assistant']);
    expect(history.map((h) => h['role']), ['user', 'assistant', 'system']);

    // The model has the emails; the reader has the summary of them.
    expect(history.last['content'], contains('token refresh was retried'));
    expect(
      transcript.map((t) => t.text).join('\n'),
      isNot(contains('token refresh was retried')),
    );
    await db.close();
  });

  test('what the summary covered is on screen, not only in the model copy',
      () async {
    // The coverage sentence is the one claim in the whole feature that has to
    // survive every hop. A summary of 18 of about 412 emails that reads as a
    // summary of the archive is the failure §2e exists to prevent, and the
    // reader is the one being misled — so it belongs in the visible turn, not
    // in the context the reader never sees.
    final db = await _freshDb('aichat_seeded_coverage_test.db');
    final id = await SummaryChatHandoff(AichatRepository(db)).create(
      QueryParser.parse('russell jong'),
      const ResultSetSummary(
        text: 'They discussed the contract.',
        coverage: SummaryCoverage.sample,
        itemsSummarized: 18,
        matchTotal: 412,
        batches: 1,
        sources: ['[1] an email'],
      ),
    );

    final (:transcript, :history) = splitConversation(
      await AichatRepository(db).getMessages(id),
    );

    final shown = transcript.map((t) => t.text).join('\n');
    expect(shown, contains('Summarized the 18 most relevant of about 412'));
    expect(shown, contains('They discussed the contract.'));
    expect(history, hasLength(3));
    await db.close();
  });
}
