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

  const ImapConnectionResult._(this.ok, this.failure, this.message);

  factory ImapConnectionResult.success() =>
      const ImapConnectionResult._(true, null, null);

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

  const ImapConnectionRequest({
    required this.host,
    required this.port,
    required this.security,
    required this.username,
    required this.password,
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
  });

  final Duration timeout;

  @override
  Future<ImapConnectionResult> test(ImapConnectionRequest request) async {
    final client = ImapClient(isLogEnabled: false);
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
      await client.login(request.username, request.password);
      return ImapConnectionResult.success();
    } catch (e) {
      return ImapConnectionResult.failure(classifyImapConnectionError(e));
    } finally {
      try {
        await client.disconnect();
      } catch (_) {}
    }
  }
}
