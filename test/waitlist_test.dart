import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:onelo/src/waitlist.dart';
import 'package:onelo/src/client.dart';
import 'package:onelo/src/types.dart';
import 'package:onelo/src/marketing_consent.dart';

class MockOneloClient extends Mock implements OneloClient {}

void main() {
  group('OneloWaitlist.join', () {
    test('delegates to OneloClient.joinWaitlist', () async {
      final mockClient = MockOneloClient();
      when(() => mockClient.joinWaitlist('beta', 'user@example.com', consent: any(named: 'consent')))
        .thenAnswer((_) async => const WaitlistResult(success: true, position: 1, alreadyJoined: false));
      final waitlist = OneloWaitlist(mockClient);
      final result = await waitlist.join('beta', email: 'user@example.com');
      expect(result.success, isTrue);
      expect(result.position, equals(1));
      verify(() => mockClient.joinWaitlist('beta', 'user@example.com', consent: null)).called(1);
    });

    test('surfaces alreadyJoined flag', () async {
      final mockClient = MockOneloClient();
      when(() => mockClient.joinWaitlist(any(), any(), consent: any(named: 'consent')))
        .thenAnswer((_) async => const WaitlistResult(success: false, alreadyJoined: true));
      final waitlist = OneloWaitlist(mockClient);
      final result = await waitlist.join('beta', email: 'user@example.com');
      expect(result.alreadyJoined, isTrue);
    });
  });

  group('OneloWaitlist.join — consent flags (#818)', () {
    test('passes the checkboxes the form showed', () async {
      final mockClient = MockOneloClient();
      const consent = OneloWaitlistConsent(marketing: true);
      when(() => mockClient.joinWaitlist('beta', 'user@example.com', consent: consent))
          .thenAnswer((_) async => const WaitlistResult(success: true, position: 2, alreadyJoined: false));
      final result = await OneloWaitlist(mockClient).join('beta', email: 'user@example.com', consent: consent);
      expect(result.success, isTrue);
      verify(() => mockClient.joinWaitlist('beta', 'user@example.com', consent: consent)).called(1);
    });

    test('the wire value carries only the given checkboxes', () {
      expect(const OneloWaitlistConsent(marketing: true).wireValue, {'marketing': true});
      expect(const OneloWaitlistConsent(marketing: false, custom: true).wireValue, {'marketing': false, 'custom': true});
      expect(const OneloWaitlistConsent().wireValue, isNull);
    });
  });
}
