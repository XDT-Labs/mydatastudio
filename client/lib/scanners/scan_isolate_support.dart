import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/services/credential_codec.dart';

/// Shared, opt-in helpers for the per-collection scan isolates.
///
/// These are deliberately small, standalone utilities that each scanner *calls*
/// — not a base class that owns the scan lifecycle. The scanners keep their own
/// control flow and source-specific code (discovery, model mapping, auth,
/// incremental strategy); only the genuinely identical mechanics live here.
/// See the "scanner convergence" entry in AUDIT.md (Phase A).

/// Standard in-isolate bootstrap: initialise the background binary messenger so
/// platform channels work off the root isolate, then install the credential
/// vault from the DEK handed in via spawn args (AUDIT M2 phase 4) so in-isolate
/// collection reads/writes and OAuth token refresh can decrypt secrets.
///
/// Call once at the top of an isolate worker, before any DB or credential
/// access. [vaultDek] may be null for sources that carry no secrets (the vault
/// is simply left locked).
void bootstrapScanIsolate(RootIsolateToken? token, Uint8List? vaultDek) {
  if (token != null) {
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  }
  CredentialCodec.installIsolateVault(vaultDek);
}

/// Replays a log record relayed from a scan isolate onto the calling isolate.
///
/// A worker's [AppLogger] reaches the console but never the log *file*:
/// `CustomLogOutput` needs `MainApp.appDataDirectory`, and that subject is
/// empty in a spawned isolate because statics aren't shared. So the worker
/// ships every record over its port (see `AppLogger.log`) and the parent
/// replays it here, where the file sink is live.
///
/// A parent that ignores these messages silently loses everything its scanner
/// logged — which is how a PST import could dump whole HTML email bodies to the
/// console with no trace of them on disk.
///
/// [tag] prefixes the replayed message (e.g. `[PstScan]`) so the origin survives
/// the hop. Returns true if [message] was a log record and has been handled.
bool relayIsolateLog(AppLogger logger, Object? message, String tag) {
  if (message is! Map || message['type'] != 'log') return false;

  final text = '$tag ${message['message']}';
  switch (message['level']) {
    case 'error':
    case 'fatal':
      logger.e(
        text,
        error: message['error'],
        stackTrace: message['stackTrace'],
      );
    case 'warning':
      logger.w(text);
    case 'debug':
    case 'trace':
      logger.d(text);
    default:
      logger.i(text);
  }
  return true;
}

/// Runs [operation], retrying on transient network failures with quadratic
/// backoff (attempt² seconds). Non-transient errors, and any error once
/// [maxRetries] is reached, are rethrown unchanged.
///
/// "Transient" = socket/IO errors, timeouts, and TLS handshake failures — the
/// classes worth a quick retry during a long cloud scan. When [logger] is
/// supplied, each retry is logged at warning level.
Future<T> retryNetworkOp<T>(
  Future<T> Function() operation, {
  AppLogger? logger,
  int maxRetries = 3,
}) async {
  int attempt = 0;
  while (true) {
    attempt++;
    try {
      return await operation();
    } catch (e) {
      final isTransient = e is io.IOException ||
          e is TimeoutException ||
          e.toString().contains('HandshakeException');
      if (isTransient && attempt < maxRetries) {
        final backoffMs = 1000 * attempt * attempt;
        logger?.w(
          'Transient network error ($e). Attempt $attempt/$maxRetries. '
          'Retrying in ${backoffMs}ms...',
        );
        await Future.delayed(Duration(milliseconds: backoffMs));
        continue;
      }
      rethrow;
    }
  }
}
