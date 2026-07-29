import 'dart:convert';

/// Utilities for fault-tolerant email decoding (Quoted-Printable, Base64, Charsets).
class EmailDecodingHelper {
  static bool _isHexDigit(int codeUnit) {
    return (codeUnit >= 48 && codeUnit <= 57) || // 0-9
        (codeUnit >= 65 && codeUnit <= 70) || // A-F
        (codeUnit >= 97 && codeUnit <= 102); // a-f
  }

  /// Safely decodes Quoted-Printable bytes or text into a clean string.
  /// Never throws on malformed '=XX' codes, trailing '=', or invalid UTF-8 sequences.
  static String decodeQuotedPrintable(List<int> bytes) {
    final input = String.fromCharCodes(bytes);
    final buffer = <int>[];
    final length = input.length;
    int i = 0;

    while (i < length) {
      final char = input.codeUnitAt(i);
      if (char == 61 /* '=' */) {
        if (i + 2 < length && input[i + 1] == '\r' && input[i + 2] == '\n') {
          // Soft line break =\r\n
          i += 3;
          continue;
        } else if (i + 1 < length && input[i + 1] == '\n') {
          // Soft line break =\n
          i += 2;
          continue;
        } else if (i + 2 < length &&
            _isHexDigit(input.codeUnitAt(i + 1)) &&
            _isHexDigit(input.codeUnitAt(i + 2))) {
          final hexStr = input.substring(i + 1, i + 3);
          final hexVal = int.parse(hexStr, radix: 16);
          buffer.add(hexVal);
          i += 3;
          continue;
        }
        // If invalid = sequence (e.g. = at end of string or non-hex), treat '=' as literal
        buffer.add(char);
        i++;
      } else {
        buffer.add(char);
        i++;
      }
    }

    try {
      return utf8.decode(buffer, allowMalformed: true);
    } catch (_) {
      return latin1.decode(buffer);
    }
  }

  /// Safely decodes base64 or base64url data without throwing padding or encoding errors.
  static List<int>? safeBase64Decode(String input) {
    try {
      final normalized = base64Url.normalize(input.trim());
      return base64Url.decode(normalized);
    } catch (_) {
      try {
        final normalized = base64.normalize(input.trim());
        return base64.decode(normalized);
      } catch (_) {
        return null;
      }
    }
  }
}
