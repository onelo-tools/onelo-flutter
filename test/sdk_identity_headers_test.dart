import 'package:flutter_test/flutter_test.dart';
import 'package:onelo/src/client.dart';
import 'package:onelo/src/version.dart';

/// #122 — the client-side header set (features / paywall / forms / waitlist /
/// feedback) names the SDK next to its version.
void main() {
  test('securityHeaders carry X-Sdk-Version and X-Onelo-Sdk-Name together', () async {
    final client = OneloClient(publishableKey: 'pk_test', apiUrl: 'https://example.com');
    final h = await client.securityHeaders();
    expect(h['X-Sdk-Version'], oneloFlutterSdkVersion);
    expect(h['X-Onelo-Sdk-Name'], 'onelo-flutter');
  });

  test('the name is the registry key', () {
    expect(oneloFlutterSdkName, 'onelo-flutter');
    expect(oneloSdkIdentityHeaders['X-Onelo-Sdk-Name'], oneloFlutterSdkName);
  });
}
