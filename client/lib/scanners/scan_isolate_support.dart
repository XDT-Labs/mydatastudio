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
