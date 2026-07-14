/// Client-side PII scrubbing for Monitor payloads — Dart port of the Swift
/// `MonitorScrubber`. Redacts sensitive VALUES (Bearer tokens, JWTs, API keys,
/// credit-card numbers) from free-text `error` strings, and whole VALUES held
/// under sensitive KEYS (`password`, `token`, `authorization`, …) from `meta`
/// maps, BEFORE the event leaves the device. The backend scrubs again
/// server-side — this is defense in depth, and it keeps secrets out of the
/// on-device buffer too.
library;

class MonitorScrubber {
  static const String redactedMarker = '[REDACTED]';
  static const int _maxDepth = 10;

  /// Key names whose whole value is redacted, matched case-insensitively as a
  /// SUBSTRING (so `sessionToken`, `myPassword` all hit).
  static const List<String> _piiKeySubstrings = [
    'password', 'passwd', 'secret', 'token', 'api_key', 'apikey',
    'authorization', 'cookie', 'credential', 'private_key', 'client_secret',
    'cvv', 'ssn',
  ];

  /// The single short word that is only PII when it stands alone as a `-`/`_`-
  /// delimited SEGMENT — so `x-api-key`, `x-anthropic-key`, `x-groq-key` are
  /// redacted, but `monkey` is not. Byte-for-byte with the Swift + backend
  /// scrubbers, which special-case ONLY the `key` segment (`x-auth-token` is
  /// already caught by the `token` substring above — no `auth` segment needed).
  static const Set<String> _piiKeySegments = {'key'};

  /// Value patterns replaced with [redactedMarker] — ported 1:1 from the backend
  /// PII_VALUE_PATTERNS (sdk_monitor.py) / Swift MonitorScrubber. ASCII-only
  /// lookarounds (underscore is NOT a boundary, so `API_sk_live_…` still latches).
  static final List<RegExp> _valuePatterns = [
    // Bearer <token> — case-insensitive keyword (matches BEARER / bearer / Bearer)
    RegExp(r'(?<![A-Za-z0-9])Bearer\s+[A-Za-z0-9\-._~+/]+=*', caseSensitive: false),
    // JWT — three base64url segments beginning eyJ
    RegExp(r'(?<![A-Za-z0-9])eyJ[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+(?![A-Za-z0-9])'),
    // Stripe-style keys: sk_/pk_/rk_ live|test
    RegExp(r'(?<![A-Za-z0-9])(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{16,}(?![A-Za-z0-9])'),
    // Onelo keys: onelo_pk|sk|rk_live|test
    RegExp(r'(?<![A-Za-z0-9])onelo_(?:pk|sk|rk)_(?:live|test)_[A-Za-z0-9]{8,}(?![A-Za-z0-9])'),
    // Credit cards — separated (Visa/MC/Amex/Discover prefixes + grouped digits)
    RegExp(r'(?<![A-Za-z0-9])(?:4[0-9]{3}|5[1-5][0-9]{2}|3[47][0-9]{2}|6(?:011|5[0-9]{2}))[\s-][0-9]{4}[\s-][0-9]{4}[\s-][0-9]{4}(?![A-Za-z0-9])'),
    // Credit cards — unseparated greedy (Visa/MC/Discover)
    RegExp(r'(?<![A-Za-z0-9])(?:4|5[1-5]|6(?:011|5))[0-9]{14,}(?![0-9])'),
    // Amex — unseparated greedy
    RegExp(r'(?<![A-Za-z0-9])3[47][0-9]{13,}(?![0-9])'),
  ];

  static bool isPiiKey(String key) {
    final lower = key.toLowerCase();
    for (final s in _piiKeySubstrings) {
      if (lower.contains(s)) return true;
    }
    for (final seg in lower.split(RegExp(r'[-_]'))) {
      if (_piiKeySegments.contains(seg)) return true;
    }
    return false;
  }

  /// Redacts sensitive value patterns from free text. Returns null for null.
  static String? scrubText(String? text) {
    if (text == null) return null;
    var out = text;
    for (final re in _valuePatterns) {
      out = out.replaceAll(re, redactedMarker);
    }
    return out;
  }

  /// Recursively scrubs a meta map. Redacts whole values under PII keys, scrubs
  /// text values, and appends a sorted `_onelo_redacted` marker listing the keys
  /// whose value was redacted (recomputed server-side, so purely informational).
  static Map<String, dynamic>? scrubMeta(Map<String, dynamic>? meta) {
    if (meta == null) return null;
    final redactedKeys = <String>[];
    final scrubbed = _scrubMap(meta, 0, redactedKeys);
    if (redactedKeys.isNotEmpty) {
      redactedKeys.sort();
      scrubbed['_onelo_redacted'] = redactedKeys;
    }
    return scrubbed;
  }

  static Map<String, dynamic> _scrubMap(Map input, int depth, List<String> redactedKeys) {
    if (depth >= _maxDepth) return {'_onelo_depth_exceeded': true};
    final out = <String, dynamic>{};
    input.forEach((k, v) {
      final key = k.toString();
      if (isPiiKey(key)) {
        out[key] = redactedMarker;
        redactedKeys.add(key);
      } else {
        out[key] = _scrubValue(v, depth, redactedKeys);
      }
    });
    return out;
  }

  static dynamic _scrubValue(dynamic v, int depth, List<String> redactedKeys) {
    if (v is String) return scrubText(v);
    if (v is Map) return _scrubMap(v, depth + 1, redactedKeys);
    if (v is List) {
      if (depth + 1 >= _maxDepth) return {'_onelo_depth_exceeded': true};
      return v.map((e) => _scrubValue(e, depth + 1, redactedKeys)).toList();
    }
    return v;
  }
}
