import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:onelo/src/waitlist.dart';
import 'package:onelo/src/client.dart';
import 'package:onelo/src/types.dart';

class MockOneloClient extends Mock implements OneloClient {}

void main() {
  group('OneloWaitlist.join', () {
    test('delegates to OneloClient.joinWaitlist', () async {
      final mockClient = MockOneloClient();
      when(() => mockClient.joinWaitlist('beta', 'user@example.com'))
        .thenAnswer((_) async => const WaitlistResult(success: true, position: 1, alreadyJoined: false));
      final waitlist = OneloWaitlist(mockClient);
      final result = await waitlist.join('beta', email: 'user@example.com');
      expect(result.success, isTrue);
      expect(result.position, equals(1));
      verify(() => mockClient.joinWaitlist('beta', 'user@example.com')).called(1);
    });

    test('surfaces alreadyJoined flag', () async {
      final mockClient = MockOneloClient();
      when(() => mockClient.joinWaitlist(any(), any()))
        .thenAnswer((_) async => const WaitlistResult(success: false, alreadyJoined: true));
      final waitlist = OneloWaitlist(mockClient);
      final result = await waitlist.join('beta', email: 'user@example.com');
      expect(result.alreadyJoined, isTrue);
    });
  });
}
