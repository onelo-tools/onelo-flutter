import 'package:http/http.dart' as http;

/// The HTTP client every Onelo module uses. Its whole job is to refuse to follow
/// redirects, and to be the ONE place that decision lives.
///
/// ── Why ──────────────────────────────────────────────────────────────────────
/// Every Onelo request carries credentials: the user's access token, the
/// publishable key, the attestation/integrity token. `dart:io`'s HttpClient
/// follows redirects by default and **re-sends the request headers to the new
/// host**. So a 3xx to a foreign origin — a hijacked or expired domain, a
/// misconfigured CDN edge, a developer pointing `apiUrl` at a tunnel — would
/// have the user's own device hand that token to whoever answered.
///
/// Nothing is lost by refusing: every Onelo endpoint is direct. A redirect from
/// our API is a misconfiguration or an attack, and either way the right answer
/// is to stop rather than to follow it with the credentials attached.
///
/// ── Why a client wrapper and not a flag at each call site ────────────────────
/// `package:http`'s convenience methods (`client.get(...)`, `client.post(...)`)
/// build the `Request` internally and expose no way to set `followRedirects`.
/// Setting it per call would mean rewriting every call in every module to the
/// verbose `Request` form — dozens of sites, each one an opportunity to forget.
/// Overriding `send` catches all of them, including any added later.
///
/// Mirrors the Android SDK, where the same default is turned off explicitly at
/// each `HttpURLConnection` (`instanceFollowRedirects = false`).
class OneloHttpClient extends http.BaseClient {
  final http.Client _inner;

  OneloHttpClient([http.Client? inner]) : _inner = inner ?? http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.followRedirects = false;
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

/// Reject a plaintext `apiUrl`.
///
/// It was previously only checked for non-blankness, so `http://` was accepted
/// and every credential above travelled in the clear, readable by anyone on the
/// same network. "I'll switch it back before release" is exactly the kind of
/// thing that ships.
///
/// Loopback AND private network ranges are allowed. Loopback alone would be too
/// strict to be workable: a developer testing on a PHYSICAL phone cannot reach
/// their machine at `localhost`, they must use its LAN address. That traffic
/// stays on the local network, so the exposure this guards against — anyone on
/// the path to a public host — does not apply.
void requireSecureApiUrl(String apiUrl) {
  final lower = apiUrl.trim().toLowerCase();
  if (lower.startsWith('https://')) return;

  // Compare the HOST, not a prefix of the whole string: `http://localhost.evil.com`
  // and `http://evil.com/localhost` must both be rejected.
  final host = lower
      .replaceFirst('http://', '')
      .split('/')
      .first
      .split(':')
      .first;
  if (_isLocalHost(host)) return;

  throw ArgumentError(
    '[Onelo] apiUrl must use https:// — got "$apiUrl". Every Onelo request '
    'carries credentials (access token, publishable key), which plaintext http '
    'exposes to anyone on the network. Loopback and private LAN ranges are '
    'allowed for local development.',
  );
}

/// Loopback, the Android emulator's host alias, and the RFC 1918 private ranges.
bool _isLocalHost(String host) {
  if (host == 'localhost' || host == '127.0.0.1' || host == '::1') return true;
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final octets = parts.map(int.tryParse).toList();
  if (octets.any((o) => o == null || o < 0 || o > 255)) return false;
  final a = octets[0]!, b = octets[1]!;
  // 10.0.0.0/8 (covers the emulator's 10.0.2.2), 192.168.0.0/16, 172.16.0.0/12.
  return a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31);
}
