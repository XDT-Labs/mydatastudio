@Tags(['live'])
library;

import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:genui/genui.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/modules/aichat/services/agent_loop.dart';
import 'package:mydatastudio/modules/aichat/services/local_llm_content_generator.dart';
import 'package:mydatastudio/modules/aichat/services/tools/tool_registry.dart';
import 'package:mydatastudio/modules/email/services/tools/email_tools.dart';
import 'package:mydatastudio/modules/search/services/tools/search_tools.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// End to end against a running aiserver and the real local model:
/// chat client → /v1/chat/completions → Gemma → tool call → our tools on a
/// seeded database → result back → answer (docs/plans/llm-tools.md, Phase 4).
///
/// Needs a server on this branch with the model on disk, so it only runs when
/// asked:
///
///     LIVE_AISERVER_URL=http://127.0.0.1:8117 flutter test test/integration/llm_tools_live_test.dart
///
/// The model's wording varies, so the assertions are about behaviour: a tool
/// was used, the answer contains the fact only the archive holds, and no
/// Gemma syntax leaked into the text.

final _url = io.Platform.environment['LIVE_AISERVER_URL'];
final _model = io.Platform.environment['LIVE_MODEL'] ?? 'gemma4:12b';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding answers every HTTP request with a fake 400. This test is
  // about the real server, so put the real client back.
  io.HttpOverrides.global = null;

  late AppDatabase db;
  late io.File dbFile;

  setUpAll(() async {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async => '.');
    final supportDir = await getApplicationSupportDirectory();
    final name = 'live_tools_${DateTime.now().microsecondsSinceEpoch}.db';
    dbFile = io.File(p.join(supportDir.path, 'data', name));
    db = await AppDatabase.create(null, supportDir.path, name);
    await db.rawDb.execute(
      'INSERT INTO collections (id, name, path, type, scanner, scan_status) '
      "VALUES ('mail', 'Gmail', '/', 'email', 'gmail', 'idle')",
    );
    for (final (id, from, subject, date, body) in [
      ('e1', 'Sarah Lee <sarah@example.com>', 'Lease renewal', '2024-04-02',
          'Hi! The apartment lease renews on May 1, and rent goes to \$2,100.'),
      ('e2', 'Bob <bob@example.com>', 'Lease question', '2024-05-10',
          'Is parking included in the lease?'),
    ]) {
      await db.rawDb.execute(
        'INSERT INTO emails (id, collection_id, date, "from", "to", subject, '
        'snippet, plain_body, body_text, has_attachments, is_deleted) '
        "VALUES (?, 'mail', ?, ?, 'me@example.com', ?, ?, ?, ?, 0, 0)",
        [id, DateTime.parse(date).millisecondsSinceEpoch, from, subject, body, body, body],
      );
    }
    MainApp.llmServiceUrl.add(_url);
  });

  tearDownAll(() async {
    await db.close();
    for (final suffix in const ['', '-wal', '-shm']) {
      final f = io.File('${dbFile.path}$suffix');
      if (f.existsSync()) f.deleteSync();
    }
  });

  Future<({List<ToolActivity> activity, List<String> answers, List<String> errors})>
  ask(LocalLlmContentGenerator gen, String question) async {
    final activity = <ToolActivity>[];
    final answers = <String>[];
    final errors = <String>[];
    final subs = [
      gen.toolActivityStream.listen(activity.add),
      gen.textResponseStream.listen(answers.add),
      gen.errorStream.listen((e) => errors.add('${e.error}')),
    ];
    await gen.sendRequest(UserMessage.text(question));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    for (final s in subs) {
      await s.cancel();
    }
    return (activity: activity, answers: answers, errors: errors);
  }

  test(
    'an archive question is answered from the archive',
    () async {
      final gen = LocalLlmContentGenerator(systemInstruction: 'You are a helpful assistant.')
        ..model = _model
        ..toolRegistry = ToolRegistry([
          SearchToolProvider(db, (_) async => null), // lexical only: no embedding model needed
          EmailToolProvider(db),
        ]);

      final r = await ask(
        gen,
        'Find the email from Sarah about the apartment lease. When does it renew?',
      );

      expect(r.errors, isEmpty);
      expect(r.activity.map((a) => a.name), contains('search'));
      expect(r.answers, hasLength(1));
      final answer = r.answers.single;
      // ignore: avoid_print
      print('ANSWER: $answer');
      expect(answer, contains('May'));
      expect(answer, isNot(contains('<|')));

      // A follow-up that needs no archive makes no tool call.
      final r2 = await ask(gen, 'What is 17 * 3? Reply with just the number.');
      expect(r2.errors, isEmpty);
      expect(r2.activity, isEmpty);
      expect(r2.answers.single, contains('51'));
    },
    skip: _url == null ? 'Set LIVE_AISERVER_URL to run against a live aiserver' : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
