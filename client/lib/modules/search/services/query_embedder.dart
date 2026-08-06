import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/modules/search/services/retrievers/vector_retriever.dart';

/// Embeds the query text through the local AI subprocess.
///
/// Every failure returns null rather than throwing, and the reasons are
/// ordinary rather than exceptional: the subprocess is spawned at launch and
/// may not have reported its port yet, the embedding model may never have been
/// downloaded, and a cold model load can outrun any sane timeout. None of that
/// should stop a keyword search from returning.
class AiServerQueryEmbedder {
  static final AppLogger _logger = AppLogger(null);

  /// The same model the scanners embed with. Comparing a query vector against
  /// stored vectors from a *different* model produces confident nonsense rather
  /// than an error, so this constant is not a default to be overridden lightly.
  static const modelName = 'Qwen/Qwen3-VL-Embedding-2B';

  /// Bounded because this sits on the critical path of a search the user is
  /// waiting on. Ten seconds is generous for a warm model and short enough
  /// that a wedged subprocess degrades to lexical-only instead of hanging the
  /// results list.
  static const timeout = Duration(seconds: 10);

  /// A [QueryEmbedder] bound to the currently-running service.
  static QueryEmbedder get instance => _embed;

  static Future<List<double>?> _embed(String text) async {
    final serviceUrl = MainApp.llmServiceUrl.valueOrNull;
    if (serviceUrl == null || serviceUrl.isEmpty) return null;

    try {
      final response = await http
          .post(
            Uri.parse('$serviceUrl/util/embedding'),
            headers: {
              'Content-Type': 'application/json',
              ...aiServerAuthHeaders(MainApp.llmServiceToken.valueOrNull),
            },
            body: jsonEncode({'model_name': modelName, 'text': text}),
          )
          .timeout(timeout);

      if (response.statusCode != 200) {
        _logger.d(
          'AiServerQueryEmbedder: ${response.statusCode}, lexical only',
        );
        return null;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final embedding = data['embedding'];
      if (embedding is! List) return null;
      return embedding.cast<num>().map((n) => n.toDouble()).toList();
    } catch (e) {
      _logger.d('AiServerQueryEmbedder: $e, lexical only');
      return null;
    }
  }
}
