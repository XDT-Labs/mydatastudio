import 'dart:async';
import 'dart:io';

import 'package:enough_mail/enough_mail.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider.dart';

enum ImapConnectionFailure { badCredentials, unreachable, unknown }

/// Maps an error thrown while connecting/logging in to something the user can
/// act on. Network-level errors (including TLS handshake) mean the host
/// settings are wrong; an [ImapException] means the server answered and
/// refused the login.
ImapConnectionFailure classifyImapConnectionError(Object error) {
  if (error is SocketException ||
      error is TimeoutException ||
      error is HandshakeException ||
      error is TlsException) {
    return ImapConnectionFailure.unreachable;
  }
  if (error is ImapException) return ImapConnectionFailure.badCredentials;
  return ImapConnectionFailure.unknown;
}

class ImapConnectionResult {
  final bool ok;
  final ImapConnectionFailure? failure;
  final String? message;

  /// The login name that worked, when it differs from the one requested
  /// (iCloud accepting the local part). Null = the requested one worked.
  final String? resolvedUsername;

  const ImapConnectionResult._(
    this.ok,
    this.failure,
    this.message, [
    this.resolvedUsername,
  ]);

  factory ImapConnectionResult.success({String? resolvedUsername}) =>
      ImapConnectionResult._(true, null, null, resolvedUsername);

  factory ImapConnectionResult.failure(
    ImapConnectionFailure failure, [
    String? detail,
  ]) {
    final base = switch (failure) {
      ImapConnectionFailure.badCredentials =>
        'The server rejected the username or password. Check them and try '
            'again (some providers require an app password).',
      ImapConnectionFailure.unreachable =>
        'Could not reach the mail server. Check the server address, port and '
            'security setting, and your network connection.',
      ImapConnectionFailure.unknown => 'Could not connect to the mail server.',
    };
    return ImapConnectionResult._(
      false,
      failure,
      detail == null || detail.isEmpty ? base : '$base ($detail)',
    );
  }
}

class ImapConnectionRequest {
  final String host;
  final int port;
  final ImapSecurity security;
  final String username;
  final String password;

  /// Registry provider id, for provider-specific login quirks.
  final String? providerId;

  const ImapConnectionRequest({
    required this.host,
    required this.port,
    required this.security,
    required this.username,
    required this.password,
    this.providerId,
  });
}

/// Verifies IMAP settings and credentials before an account is saved.
/// Injectable so UI tests never touch the network.
abstract class ImapConnectionTester {
  Future<ImapConnectionResult> test(ImapConnectionRequest request);
}

class EnoughMailImapConnectionTester implements ImapConnectionTester {
  const EnoughMailImapConnectionTester({
    this.timeout = const Duration(seconds: 15),
    this.clientFactory = _defaultClient,
  });

  final Duration timeout;

  /// Builds the IMAP client for each attempt; replaced in tests.
  final ImapClient Function() clientFactory;

  static ImapClient _defaultClient() => ImapClient(isLogEnabled: false);

  @override
  Future<ImapConnectionResult> test(ImapConnectionRequest request) async {
    final result = await _attempt(request, request.username);
    // Some iCloud accounts only accept the name before the '@'. Retry once
    // with it, and report it so the saved account uses the one that works.
    final at = request.username.indexOf('@');
    if (result.failure == ImapConnectionFailure.badCredentials &&
        request.providerId == 'icloud' &&
        at > 0) {
      final retry = await _attempt(request, request.username.substring(0, at));
      if (retry.ok) return retry;
    }
    return result;
  }

  Future<ImapConnectionResult> _attempt(
    ImapConnectionRequest request,
    String username,
  ) async {
    final client = clientFactory();
    try {
      await client.connectToServer(
        request.host,
        request.port,
        isSecure: request.security == ImapSecurity.ssl,
        timeout: timeout,
      );
      if (request.security == ImapSecurity.startTls) {
        await client.startTls();
      }
      await client.login(username, request.password);
      return ImapConnectionResult.success(
        resolvedUsername: username == request.username ? null : username,
      );
    } catch (e) {
      return ImapConnectionResult.failure(classifyImapConnectionError(e));
    } finally {
      try {
        await client.disconnect();
      } catch (_) {}
    }
  }
}
